#if DEBUG
import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Foundation
import Testing

/// 2 panes side by side, each with an agent page in Chromium, and the app is not active: no page window is the key
/// window. The keyboard is in the page of the second pane. A held key that the hold replays must go to the page
/// window of the second pane, and its touch mark and gesture record to that pane's view.
///
/// The model: each page is a fake Chromium page and each page's window is a `PageWindow` over its pane. The row
/// says where the keyboard is by the page window's own first responder: the second page window has a view with
/// the keyboard, the first has none.
@MainActor @Suite(.serialized, .closesItsWindows)
struct NewTabHoldPageWindowPickTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Stands for the view of Chromium that has the keyboard in a page's window.
    private final class KeyView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Stands for a page's window of Chromium: a child window of the app's window. It counts the events that it gets,
    /// and it says that it is visible from the setup's end, so the row needs no display.
    private final class PageWindow: NSWindow {
        var got = 0
        var saysVisible = false
        override var isVisible: Bool { saysVisible || super.isVisible }
        override func sendEvent(_ event: NSEvent) { got += 1 }
    }

    private static func paneWithAChromiumPage(from file: URL) async throws -> (AgentPaneView, FakeChromiumPage) {
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, testRoot: true, chromium: hosting))
        let page = try #require(view.page)
        await page.chromiumStart?.value
        let chromium = try #require(hosting.made.first, "setup: the view made no Chromium page")
        view.loadingView.leave(over: view.pageContent, fades: false)
        return (view, chromium)
    }

    @Test func aReplayedKeyGoesToThePageWindowThatHasTheKeyboard() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: "hold-page-window-pick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "index.html")
        try Data("<html><body><textarea></textarea></body></html>".utf8).write(to: file)
        let first = try await Self.paneWithAChromiumPage(from: file)
        let second = try await Self.paneWithAChromiumPage(from: file)
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        var pageWindows: [PageWindow] = []
        for (index, pane) in [first.0, second.0].enumerated() {
            pane.frame = CGRect(x: CGFloat(index) * 200, y: 0, width: 200, height: 300)
            content.addSubview(pane)
            content.layoutSubtreeIfNeeded()
            let page = PageWindow(contentRect: window.convertToScreen(pane.convert(pane.bounds, to: nil)), styleMask: [.borderless], backing: .buffered, defer: true)
            page.isReleasedWhenClosed = false
            page.contentView = KeyView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
            window.addChildWindow(page, ordered: .above)
            page.saysVisible = true
            pageWindows.append(page)
        }
        defer {
            first.0.page?.close()
            second.0.page?.close()
            for page in pageWindows {
                page.saysVisible = false
                window.removeChildWindow(page)
                page.close()
            }
            window.close()
        }
        let firstWindow = pageWindows[0], secondWindow = pageWindows[1]
        try #require(window.childWindows?.first === firstWindow && secondWindow.parent === window,
                     "setup: the 2 page windows are not the window's child windows, the first pane's first")
        try #require(first.1.visibility.last == true && second.1.visibility.last == true,
                     "setup: the app did not tell Chromium that each of the 2 pages shows")
        try #require(AgentPaneView.chromiumAgentPane(under: firstWindow, in: window) === first.0
                        && AgentPaneView.chromiumAgentPane(under: secondWindow, in: window) === second.0,
                     "setup: the lookup does not answer each page window's own pane view")
        window.makeFirstResponder(nil)
        try #require(window.firstResponder === window, "setup: a view of the window has the keyboard")
        try #require(secondWindow.makeFirstResponder(secondWindow.contentView) && firstWindow.firstResponder === firstWindow,
                     "setup: the keyboard is not in the second page window only")
        // The router holds its registry unowned: the test keeps it alive to its end.
        let registry = ActionRegistry.standard()
        defer { withExtendedLifetime(registry) {} }
        let router = KeyRouter(registry: registry)
        let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        let letter = try #require(NSEvent(cgEvent: cgEvent))
        NewTabInputCoordinator.replay(letter, held: letter, in: window, router: router)
        let marks = "the first pane's view: mark \(first.0.model.hostTouch.marked); the second pane's view: mark \(second.0.model.hostTouch.marked)"
        print("NewTabHoldPageWindowPickTests: a replayed letter with the keyboard in the second pane's page: the first page window got "
            + "\(firstWindow.got) event(s), want 0; the second got \(secondWindow.got), want 1; \(marks)")
        try #require(firstWindow.got + secondWindow.got == 1, "setup: the replay did not send the letter to one page window")
        #expect(secondWindow.got == 1 && firstWindow.got == 0, "the held key went to the page window of the pane that does not have the keyboard")
        #expect(second.0.model.hostTouch.marked && !first.0.model.hostTouch.marked, "the letter's touch mark is not in the second pane's view only: \(marks)")
    }
}
#endif
