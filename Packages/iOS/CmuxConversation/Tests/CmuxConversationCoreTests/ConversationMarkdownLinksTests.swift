import Foundation
import Testing
@testable import CmuxConversationCore

/// Agents' Markdown links show as their label in a bubble, not as raw syntax.
@Suite struct ConversationMarkdownLinksTests {
    @Test func cmuxLinksBecomeTheirLabels() {
        let text = "Blocked: [PR #23952: land Chief cloud](cmux://workspace/ws_220f9a1b2c3d4e5f) and [a1](cmux://chief/9d99fda0/session/01a1675b-0000-4000-8000-000000000001)."
        let result = ConversationMarkdownLinks.extract(text)
        #expect(result.text == "Blocked: PR #23952: land Chief cloud and a1.")
        #expect(result.links.count == 2)
        let ns = result.text as NSString
        #expect(ns.substring(with: result.links[0].range) == "PR #23952: land Chief cloud")
        #expect(result.links[0].url.absoluteString == "cmux://workspace/ws_220f9a1b2c3d4e5f")
        #expect(ns.substring(with: result.links[1].range) == "a1")
        #expect(result.links[1].url.scheme == "cmux")
    }

    @Test func webAndFileLinksAndPlainTextAreHandled() {
        let result = ConversationMarkdownLinks.extract("See [#1](https://github.com/o/r/pull/1), [notes](file:///tmp/a.md), ![img](https://x/y.png) and [not a link](nope)")
        #expect(result.text == "See #1, notes, img and [not a link](nope)")
        #expect(result.links.map(\.url.absoluteString) == ["https://github.com/o/r/pull/1", "file:///tmp/a.md", "https://x/y.png"])
        #expect(ConversationMarkdownLinks.extract("no links here").links.isEmpty)
    }

    /// Lawrence, 2026-11-20: a Chief picture (`![alt](src)`, a screenshot on the Mac) showed as its Markdown. The
    /// phone cannot draw a Mac's file, so a picture shows its alt text (its file name when it has none), a link
    /// when the picture is on the web.
    @Test func picturesShowTheirAltTextNeverTheirSyntax() {
        let result = ConversationMarkdownLinks.extract("Before: ![before, light](/Users/me/shots/b.png) after: ![](https://x/after.png) done")
        #expect(result.text == "Before: before, light after: after.png done")
        #expect(result.links.map(\.url.absoluteString) == ["https://x/after.png"])
        let ns = result.text as NSString
        #expect(result.links.first.map { ns.substring(with: $0.range) } == "after.png")
    }

    @Test func mentionsMoveWithTheText() {
        let text = "[PR](https://a.b/c) ping @Ana"
        let at = (text as NSString).range(of: "@Ana")
        let result = ConversationMarkdownLinks.extract(text, mentions: [ConversationMention(participantID: "ana", location: at.location, length: at.length)])
        #expect(result.text == "PR ping @Ana")
        #expect(result.mentions.count == 1)
        #expect((result.text as NSString).substring(with: result.mentions[0].nsRange) == "@Ana")
    }
}
