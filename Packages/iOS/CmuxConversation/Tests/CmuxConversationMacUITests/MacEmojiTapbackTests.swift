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
        let picker = MacReactionPickerView(current: .emoji("\u{1F680}")) { picked = $0 }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(picker)
        #expect(views.contains { $0.accessibilityIdentifier() == "conversation.tapback.custom" && $0.accessibilityLabel() == "Add custom emoji reaction" })
        let mine = try #require(views.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "conversation.tapback.\u{1F680}" })
        mine.performClick(nil)
        #expect(picked == .emoji("\u{1F680}"))
        #expect(picker.capsuleSize.width == CGFloat(ConversationReaction.allCases.count + 1) * 36 + 12)
    }
}
#endif
