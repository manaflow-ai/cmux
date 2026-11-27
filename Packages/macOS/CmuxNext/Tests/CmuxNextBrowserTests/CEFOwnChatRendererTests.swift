import Foundation
import Testing
@testable import CmuxNextBrowser

/// The agent chat the person types in gets a renderer of its own (chat-typing-while-streaming): the most
/// recently focused agent chat's browser is named to the shim, which answers its document with the
/// own-renderer headers; every other chat keeps sharing the one chat renderer.
@MainActor
@Suite struct CEFOwnChatRendererTests {
    final class Page {}
    let chat = URL(string: "cmux-page://cmux.agent/")
    let web = URL(string: "https://example.com/")

    @Test func theFocusedChatIsNamed() {
        var named: [Int32] = []
        let renderer = CEFOwnChatRenderer { named.append($0) }
        let a = Page(), b = Page()
        renderer.focused(ObjectIdentifier(a), url: chat, browser: 3)
        renderer.focused(ObjectIdentifier(b), url: chat, browser: 5)
        #expect(named == [3, 5])
    }

    @Test func aWebPageOrAnotherCmuxPageKeepsTheChat() {
        var named: [Int32] = []
        let renderer = CEFOwnChatRenderer { named.append($0) }
        let a = Page(), w = Page(), m = Page()
        renderer.focused(ObjectIdentifier(a), url: chat, browser: 3)
        renderer.focused(ObjectIdentifier(w), url: web, browser: 4)
        renderer.focused(ObjectIdentifier(m), url: URL(string: "cmux-page://cmux.markdown/"), browser: 6)
        #expect(named == [3])
        #expect(renderer.named == 3)
    }

    /// A new chat is focused before Chromium made its browser: it is named in the turn its browser is
    /// attached, before the shim answers its first document (one UI turn later).
    @Test func aChatFocusedBeforeItsBrowserIsNamedOnAttach() {
        var named: [Int32] = []
        let renderer = CEFOwnChatRenderer { named.append($0) }
        let old = Page(), new = Page()
        renderer.focused(ObjectIdentifier(old), url: chat, browser: 3)
        renderer.focused(ObjectIdentifier(new), url: chat, browser: nil)
        renderer.attached(ObjectIdentifier(old), browser: 3)
        renderer.attached(ObjectIdentifier(new), browser: 9)
        #expect(named == [3, 0, 9])
    }
}
