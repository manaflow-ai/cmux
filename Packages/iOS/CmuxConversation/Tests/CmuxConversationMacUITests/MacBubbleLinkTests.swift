import AppKit
import Foundation
import Testing
@testable import CmuxConversationCore
@testable import CmuxConversationMacUI

/// Markdown links (an agent's `[label](url)`, as Chief sends them): the
/// label shows in the bubble, underlined, and a click on it opens the URL.
@MainActor
@Suite(.serialized) struct MacBubbleLinkTests {
    static let url = URL(string: "https://github.com/manaflow-ai/cmux/pull/1")!

    static func linked() -> ConversationMessage {
        let text = "opened PR #1 for review"
        let location = (text as NSString).range(of: "PR #1").location
        return ConversationMessage(id: "m7", seq: 7, clientMessageID: nil, senderID: "lc", sentAt: Date(), text: text,
                                   links: [ConversationTextLink(location: location, length: 5, url: url)])
    }

    @Test func markdownLinkLabelIsUnderlinedAndOpensItsURLOnClick() async throws {
        let lab = try await Lab(extra: [Self.linked()])
        var opened: [URL] = []
        lab.controller.openURL = { opened.append($0) }
        let bubble = try #require(lab.bubbleText(containing: "PR #1"))
        let range = (bubble.string as NSString).range(of: "PR #1")
        let storage = try #require(bubble.textStorage)
        #expect(storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)

        lab.click(try lab.point(of: "PR #1", in: bubble, edge: .middle), count: 1)
        #expect(opened == [Self.url])

        // Plain words next to the label open nothing.
        lab.click(try lab.point(of: "review", in: bubble, edge: .middle), count: 1)
        #expect(opened == [Self.url])
    }
}
