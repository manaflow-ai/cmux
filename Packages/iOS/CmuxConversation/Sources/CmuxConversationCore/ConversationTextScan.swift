import Foundation

/// Cheap, exact prefilters for per-message text checks that run over every
/// loaded message when the transcript rebuilds its rows.
public enum ConversationTextScan {
    /// Longest RGI emoji sequences (families with skin tones, tag flags) are
    /// under 40 UTF-8 bytes; three of them fit comfortably in this budget.
    static let emojiOnlyByteBudget = 192

    /// False when `text` certainly is not one to three emoji: an ASCII letter
    /// or punctuation that no emoji contains, or more non-whitespace bytes
    /// than three emoji can take. True means "run the full grapheme check".
    /// Scans bytes with an early exit, so ordinary messages cost a byte or
    /// two instead of a trim plus a grapheme walk of the whole text.
    public static func mayBeEmojiOnly(_ text: String) -> Bool {
        var bytes = 0
        for byte in text.utf8 {
            switch byte {
            case 0x09...0x0D, 0x20:
                continue
            case 0x23, 0x2A, 0x30...0x39:
                // Keycap bases (#, *, 0-9) start emoji sequences.
                bytes += 1
            case 0x21...0x7E:
                return false
            default:
                bytes += 1
            }
            if bytes > emojiOnlyByteBudget { return false }
        }
        return bytes > 0
    }
}
