import AppKit
import CmuxNextPages
import Foundation
import Testing

/// Leo 2026-10-21, as in Chrome: a plain click on a chat's link opens its tab in front, a
/// Cmd-click in the background.
@MainActor struct LinkRouterBackgroundClickTests {
    @Test func aCmdClickInAPageViewOpensInTheBackground() throws {
        let router = LinkRouter()
        router.routing = { .fallback }
        var background: [Bool] = []
        router.openInCmux = { _, inBackground, _ in background.append(inBackground) }
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/1"))
        router.open(url, modifiers: [], from: NSView())
        router.open(url, modifiers: [.command], from: NSView())
        router.open(url, modifiers: [.command, .option], from: NSView())
        #expect(background == [false, true, true], "a plain click opened in the background or a Cmd-click in front")
    }

    /// An app link (a cmux.com agent link) that falls back to its web page keeps the click: a
    /// Cmd-click still opens that page in the background, beside the tab it was clicked in.
    @Test func anAppLinkFallbackKeepsTheClick() throws {
        let router = LinkRouter()
        router.routing = { .fallback }
        var opened: [(Bool, String?)] = []
        router.openInCmux = { _, inBackground, source in opened.append((inBackground, source)) }
        router.sourceTab = { _ in "tab-1" }
        router.appLink = { url, click in router.open(url, as: click); return true }
        let url = try #require(URL(string: "https://cmux.com/deeplink/agent?session=s&host=h"))
        router.open(url, modifiers: [.command], from: NSView())
        #expect(opened.map(\.0) == [true], "the fallback dropped the Cmd-click's background")
        #expect(opened.map(\.1) == ["tab-1"], "the fallback dropped the clicked tab")
    }
}
