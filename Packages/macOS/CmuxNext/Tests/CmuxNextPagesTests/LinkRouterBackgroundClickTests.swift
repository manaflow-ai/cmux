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
}
