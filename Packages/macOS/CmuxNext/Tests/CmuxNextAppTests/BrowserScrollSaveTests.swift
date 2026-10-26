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
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/a"), origin: .user))
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
}
