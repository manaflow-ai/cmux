import AppKit
import Testing
import WebKit
@testable import CmuxNextBrowser

/// A page may hide the browser chrome (pane fullscreen) only in answer to
/// the user, and Escape always brings the chrome back: otherwise a page
/// can hide the address bar and draw a fake one.
@MainActor @Suite struct PaneFullscreenGestureTests {
    private func makeTab(html: String) throws -> WebKitTab {
        let engine = WebKitEngine(profileStore: WebKitProfileStore(factory: FakeDataStoreFactory()), applicationNameForUserAgent: nil)
        let url = try #require(URL(string: "data:text/html;charset=utf-8," + html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!))
        return engine.makeWebKitTab(initialURL: url)
    }

    private func waitForLoad(_ tab: WebKitTab) async throws {
        for _ in 0..<400 where tab.webView.isLoading || tab.webView.url == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        // Scripts after load run within a few turns.
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func aPageCannotHideTheChromeWithoutTheUser() async throws {
        let html = """
        <html><body><div id=d>x</div><script>
        document.getElementById('d').requestFullscreen();
        window.webkit.messageHandlers.cmuxPaneFullscreen.postMessage(true);
        </script></body></html>
        """
        let tab = try makeTab(html: html)
        try await waitForLoad(tab)
        #expect(tab.state.isContentFullscreen == false)
        tab.close()
    }

    @Test func escapeAlwaysBringsTheChromeBack() async throws {
        let tab = try makeTab(html: "<html><body>page</body></html>")
        try await waitForLoad(tab)
        tab.apply(.contentFullscreenChanged(true))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                   isARepeat: false, keyCode: 53))
        tab.webView.keyDown(with: escape)
        #expect(tab.state.isContentFullscreen == false)
        tab.close()
    }
}
