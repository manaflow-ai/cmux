import CmuxBrowser
import CmuxCEF
import Foundation
import Testing
@testable import CmuxCEFBrowser

@Suite
struct CEFBrowserPageMappingTests {
    @Test func stateMapsEveryField() {
        var cef = CEFBrowserState()
        cef.url = URL(string: "https://example.com/")
        cef.title = "Example"
        cef.isLoading = true
        cef.canGoBack = true
        cef.progress = 0.5
        cef.zoom = 1.25
        cef.isFullscreen = true
        cef.isUnresponsive = true
        let state = CEFBrowserPage.pageState(cef)
        #expect(state.url == URL(string: "https://example.com/"))
        #expect(state.title == "Example")
        #expect(state.isLoading)
        #expect(state.canGoBack)
        #expect(!state.canGoForward)
        #expect(state.estimatedProgress == 0.5)
        #expect(state.pageZoom == 1.25)
        #expect(state.isContentFullscreen)
        #expect(state.isUnresponsive)
        #expect(state.processExit == nil)
    }

    @Test func tabPastThePageEdgeLeavesThePage() {
        #expect(CEFBrowserPage.pageEvent(forShimEvent: .takeFocus(browser: 1, forward: true)) == .focusLeftPage(forward: true))
        #expect(CEFBrowserPage.pageEvent(forShimEvent: .takeFocus(browser: 1, forward: false)) == .focusLeftPage(forward: false))
    }

    @Test func passThroughShimEventsMap() {
        #expect(CEFBrowserPage.pageEvent(forShimEvent: .devToolsOpened(browser: 1, devTools: 2, docked: true))
            == .devToolsVisibilityChanged(true))
        #expect(CEFBrowserPage.pageEvent(forShimEvent: .devToolsClosed(browser: 1, devTools: 2))
            == .devToolsVisibilityChanged(false))
        #expect(CEFBrowserPage.pageEvent(forShimEvent: .fullscreen(browser: 1, entering: true)) == .contentFullscreenChanged(true))
        #expect(CEFBrowserPage.pageEvent(forShimEvent: .renderUnresponsive(browser: 1)) == .unresponsiveChanged(true))
        #expect(CEFBrowserPage.pageEvent(forShimEvent: .renderResponsive(browser: 1)) == .unresponsiveChanged(false))
        #expect(CEFBrowserPage.pageEvent(forShimEvent: .closeRequested(browser: 1)) == nil)
    }

    @Test func emptyTitleIsNil() {
        #expect(CEFBrowserPage.pageState(CEFBrowserState()).title == nil)
    }

    @Test(arguments: [
        (0, BrowserPageProcessExit.Kind.other),
        (1, .killed),
        (2, .crashed),
        (3, .outOfMemory),
        (4, .launchFailed),
        (5, .other),
    ])
    func terminationStatusMaps(status: Int, kind: BrowserPageProcessExit.Kind) {
        #expect(CEFBrowserPage.processExit(status: status, code: 9).kind == kind)
        #expect(CEFBrowserPage.processExit(status: status, code: 9).status == 9)
    }

    @Test func unavailableReasonsMap() {
        #expect(CEFUnavailableReason.notBundled.browserEngineReason == .notBundled)
        #expect(CEFUnavailableReason.startFailed("x").browserEngineReason == .startFailed("x"))
        #expect(CEFUnavailableReason.shutDown.browserEngineReason == .shutDown)
        #expect(CEFBrowserPage.engineError(.browserClosed) == .pageClosed)
        #expect(CEFBrowserPage.engineError(.devTools("boom")) == .javaScript("boom"))
    }

    @Test func clickBecomesPressAndRelease() {
        let commands = CEFBrowserPage.inputCommands(
            for: .click(at: CGPoint(x: 10, y: 20), button: .left, clickCount: 1, modifiers: [.shift, .command])
        )
        #expect(commands.map(\.0) == ["Input.dispatchMouseEvent", "Input.dispatchMouseEvent"])
        #expect(commands[0].1["type"] as? String == "mousePressed")
        #expect(commands[1].1["type"] as? String == "mouseReleased")
        #expect(commands[0].1["modifiers"] as? Int == 12)
    }

    @Test func insertTextUsesInsertText() {
        let commands = CEFBrowserPage.inputCommands(for: .insertText("hi"))
        #expect(commands.count == 1)
        #expect(commands[0].0 == "Input.insertText")
        #expect(commands[0].1["text"] as? String == "hi")
    }

    @Test func dialogsWithoutADelegateGetChromesDefaults() {
        #expect(CEFBrowserPage.defaultResponse(for: .alert) == .accept(text: nil))
        #expect(CEFBrowserPage.defaultResponse(for: .beforeUnload(isReload: false)) == .accept(text: nil))
        #expect(CEFBrowserPage.defaultResponse(for: .confirm) == .dismiss)
        #expect(CEFBrowserPage.defaultResponse(for: .prompt(defaultText: "x")) == .dismiss)
    }
}
