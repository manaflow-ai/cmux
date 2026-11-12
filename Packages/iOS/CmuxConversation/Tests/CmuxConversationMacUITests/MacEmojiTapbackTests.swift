#if os(macOS)
import AppKit
import CmuxConversationCore
import Testing
@testable import CmuxConversationMacUI

/// The Mac picker's emoji circle opens the Character Viewer; its insertion
/// becomes a custom emoji tapback.
@MainActor @Suite struct MacEmojiTapbackTests {
    @Test func characterViewerInsertionPicksOneEmojiOnly() {
        let input = MacEmojiInputView()
        var picked: [String] = []
        input.onEmoji = { picked.append($0) }
        input.insertText("\u{1F525}", replacementRange: NSRange(location: NSNotFound, length: 0))
        input.insertText(NSAttributedString(string: "\u{1F44F}\u{1F3FD}"), replacementRange: NSRange(location: NSNotFound, length: 0))
        input.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        input.insertText("\u{1F525}\u{1F525}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(picked == ["\u{1F525}", "\u{1F44F}\u{1F3FD}"])
    }

    @Test func pickerOffersTheCustomCircleAndMyCustomEmojiSelected() throws {
        var picked: ConversationReaction?
        let picker = MacReactionPickerView(current: .emoji("\u{1F680}"), offersCustomEmoji: true) { picked = $0 }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(picker)
        #expect(views.contains { $0.accessibilityIdentifier() == "conversation.tapback.custom" && $0.accessibilityLabel() == "Add custom emoji reaction" && !$0.isHidden })
        let mine = try #require(views.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "conversation.tapback.\u{1F680}" })
        mine.performClick(nil)
        #expect(picked == .emoji("\u{1F680}"))
        #expect(picker.capsuleSize.width == CGFloat(ConversationReaction.allCases.count + 1) * 36 + 12)
    }

    /// `ConversationFeatures.customEmojiReactions` is off: the picker offers
    /// the six classics only (no emoji circle), but an emoji I already gave
    /// still shows, selected, so I can remove it.
    @Test func customEmojiSwitchHidesTheEmojiCircleButKeepsMyEmoji() throws {
        #expect(ConversationFeatures.customEmojiReactions == false)
        var picked: ConversationReaction?
        let picker = MacReactionPickerView(current: .emoji("\u{1F680}")) { picked = $0 }
        picker.place(capsule: CGRect(x: 0, y: 0, width: picker.capsuleSize.width, height: 42), circleCenter: CGPoint(x: 400, y: 60), outgoing: false)
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let circle = try #require(all(picker).first { $0.accessibilityIdentifier() == "conversation.tapback.custom" })
        #expect(circle.isHidden)
        #expect(!picker.contains(CGPoint(x: 400, y: 60)))
        #expect(!(picker.accessibilityChildren() ?? []).contains { ($0 as? NSView) === circle })
        let mine = try #require(all(picker).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "conversation.tapback.\u{1F680}" })
        mine.performClick(nil)
        #expect(picked == .emoji("\u{1F680}"))
        let classics = MacReactionPickerView(current: .heart) { _ in }
        #expect(classics.capsuleSize.width == CGFloat(ConversationReaction.allCases.count) * 36 + 12)
    }
}
#endif
