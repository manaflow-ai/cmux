import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationTextScanTests {
    /// The full grapheme check the row builders run after the prefilter.
    private func fullCheck(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return false }
        return trimmed.allSatisfy { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || (character.unicodeScalars.first?.properties.isEmoji == true && character.unicodeScalars.count > 1)
        }
    }

    @Test func prefilterNeverRejectsEmojiOnlyText() {
        let emojiOnly = [
            "😀", " 😀\n", "👍🏽", "❤️", "1️⃣", "#️⃣", "*️⃣", "🇯🇵", "🏴󠁧󠁢󠁥󠁮󠁧󠁿",
            "👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦", "🧑🏽‍🤝‍🧑🏿🧑🏽‍🤝‍🧑🏿🧑🏽‍🤝‍🧑🏿", "🏴󠁧󠁢󠁳󠁣󠁴󠁿🏴󠁧󠁢󠁷󠁬󠁳󠁿🏴󠁧󠁢󠁥󠁮󠁧󠁿", "😂😂😂",
        ]
        for text in emojiOnly {
            #expect(fullCheck(text), "\(text)")
            #expect(ConversationTextScan.mayBeEmojiOnly(text), "\(text)")
        }
    }

    @Test func prefilterRejectsOrdinaryText() {
        for text in ["hello", "ok 😀", "😀!", "", "   \n", String(repeating: "x", count: 10_000), "1", "#"] {
            #expect(!fullCheck(text) || ConversationTextScan.mayBeEmojiOnly(text))
        }
        #expect(!ConversationTextScan.mayBeEmojiOnly("hello"))
        #expect(!ConversationTextScan.mayBeEmojiOnly(String(repeating: "x", count: 10_000)))
        #expect(!ConversationTextScan.mayBeEmojiOnly(String(repeating: "😀", count: 100)))
        #expect(!ConversationTextScan.mayBeEmojiOnly("  \n"))
    }
}
