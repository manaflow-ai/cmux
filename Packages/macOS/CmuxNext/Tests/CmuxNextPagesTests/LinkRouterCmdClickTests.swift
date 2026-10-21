import AppKit
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Leo 2026-10-20: a pull request opened from a chat landed in a split beside it. Every surface's
/// web link reaches the App through ``LinkRouter/openInCmux``; only a terminal's Cmd-click says
/// so (`cmdClick`), and the App places only that one by `layout.linkPlacement`. A link clicked in
/// a chat, Home or a page opens as a tab of its own pane.
@MainActor struct LinkRouterCmdClickTests {
    private static func router() -> (LinkRouter, () -> [Bool]) {
        let router = LinkRouter()
        router.routing = { .fallback }
        var asked: [Bool] = []
        router.openInCmux = { _, _, _, cmdClick in asked.append(cmdClick) }
        return (router, { asked })
    }

    @Test func aLinkClickedInAPageViewIsNoCmdClick() throws {
        let (router, asked) = Self.router()
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/1"))
        #expect(router.open(url, from: NSView()) == .cmuxBrowser)
        router.open(url, source: "tab")
        #expect(asked() == [false, false], "a page's link was placed like a terminal's Cmd-click")
    }

    @Test func aTerminalsCmdClickSaysSo() throws {
        let (router, asked) = Self.router()
        router.open(try #require(URL(string: "https://example.com")), source: "tab", cmdClick: true)
        #expect(asked() == [true])
    }

    /// Leo 2026-10-21, as in Chrome: a plain click on a chat's link opens its tab in front, a
    /// Cmd-click in the background.
    @Test func aCmdClickInAPageViewOpensInTheBackground() throws {
        let router = LinkRouter()
        router.routing = { .fallback }
        var background: [Bool] = []
        router.openInCmux = { _, inBackground, _, _ in background.append(inBackground) }
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/1"))
        router.open(url, modifiers: [], from: NSView())
        router.open(url, modifiers: [.command], from: NSView())
        router.open(url, modifiers: [.command, .option], from: NSView())
        #expect(background == [false, true, true], "a plain click opened in the background or a Cmd-click in front")
    }
}
