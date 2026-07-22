#if os(iOS)
import Foundation

// Owns an immutable defensive copy, so concurrent TextKit readers cannot observe mutation.
struct TranscriptAttributedText: @unchecked Sendable {
    let value: NSAttributedString

    init(value: NSAttributedString) {
        self.value = NSAttributedString(attributedString: value)
    }
}
#endif
