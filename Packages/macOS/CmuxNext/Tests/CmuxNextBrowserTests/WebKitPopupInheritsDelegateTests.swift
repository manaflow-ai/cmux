import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing
import CmuxNextTestSupport

/// ask-2d244f2b2e (Leo: "there is similar thing maybe with probably logins and redirects and popups
/// and whatnot"): in WebKit, a sized popup (OAuth, payment) sent to an attachment never started its
/// download, and its `window.close()` never closed its window. The popup page had no delegate: no
/// host installs a popup page as a tab, and WebKit, unlike Chromium (`CEFTab.inheritDelegates`), did
/// not hand it the opener's. Its intents now go where its opener's go.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(1))) struct WebKitPopupInheritsDelegateTests {
    @Test func aSizedPopupsIntentsReachItsOpenersHost() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let host = Host()
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())  // the tab holds its engine weakly
        let opener = engine.makeWebKitTab()
        defer { opener.close() }
        opener.delegate = host
        window.contentView = opener.contentView
        opener.load(try #require(URL(string: "about:blank")))
        try await Self.until("the opener loads") {
            (try? await opener.evaluate("document.readyState", world: .page, gesture: .agent)) == .string("complete")
        }

        _ = try await opener.evaluate("window.open('about:blank', 'signin', 'width=320,height=240') !== null",
                                      world: .page, gesture: .agent)
        try await Self.until("the popup is asked for") { host.popup != nil }
        let popup = try #require(host.popup as? WebKitTab)
        defer { popup.close() }
        #expect(popup.delegate === host, "the popup page has no host for its intents")

        // The popup's own window.close() reaches the host (which closes its window).
        _ = try? await popup.evaluate("window.close(); true", world: .page, gesture: .agent)
        try await Self.until("the popup's close reaches the host") { host.closed.contains { $0 === popup } }
    }

    private static func until(_ what: String, _ done: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !(await done()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out: \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The opener's host: records the popup it is asked to show and the pages that asked to close.
    final class Host: BrowserTabDelegate {
        private(set) var popup: (any BrowserTab)?
        private(set) var closed: [any BrowserTab] = []
        func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
            switch intent {
            case .openPopup(let child, _): popup = child
            case .close: closed.append(tab)
            default: break
            }
        }
    }
}
