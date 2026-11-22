import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserHistory
import CmuxNextDaemon
import Foundation
import Testing

/// A page's scroll position fires no event, so it used to be measured only
/// at quit and a crash lost it. Leaving the app saves it too.
@MainActor
struct BrowserScrollSaveTests {
    final class Sent {
        var histories: [FrontendBrowserHistory] = []
    }

    @Test func leavingTheAppSavesTheShownPagesScrollPosition() async throws {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/a")))
        tab.scrollPosition = { 640 }
        let sent = Sent()
        let center = NotificationCenter()
        // The navigation write-back waits an hour: only leaving the app writes.
        let writer = BrowserHistoryWriter(page: tab, recorded: nil, delay: .seconds(3600),
                                          sleep: { try await Task.sleep(for: $0) }, center: center,
                                          send: { history in sent.histories.append(history); return true })
        defer { writer.cancel() }

        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while sent.histories.last?.entries.compactMap(\.scrollY).last != 640, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sent.histories.last?.entries.compactMap(\.scrollY).last == 640, "the scroll position waited for quit")
    }

    /// The person never leaves the app and it crashes: the page's own report of where its scrolling
    /// settled is already saved (restore journey, crash variant: 1500 -> 0 before).
    @Test func aSettledScrollIsSavedWhileThePersonStaysInTheApp() async throws {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/tall")))
        // Measuring the page answers nothing: only the page's own report may carry the position.
        tab.scrollPosition = { nil }
        let sent = Sent()
        let writer = BrowserHistoryWriter(page: tab, recorded: nil, delay: .milliseconds(10),
                                          sleep: { try await Task.sleep(for: $0) }, center: NotificationCenter(),
                                          send: { history in sent.histories.append(history); return true })
        defer { writer.cancel() }

        tab.simulate(.pageScrolled(1500))
        let deadline = ContinuousClock.now + .seconds(5)
        while sent.histories.last?.entries.compactMap(\.scrollY).last != 1500, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sent.histories.last?.entries.compactMap(\.scrollY).last == 1500, "the scroll waited for the person to leave the app or quit")
    }
}
