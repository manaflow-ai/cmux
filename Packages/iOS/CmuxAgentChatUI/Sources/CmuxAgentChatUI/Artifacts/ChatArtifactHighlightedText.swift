import Foundation

/// An immutable attributed-string snapshot produced by the background highlighter.
///
/// SAFETY: `value` is copied into an immutable `NSAttributedString` before transfer
/// and is only read after the producing actor has returned it.
final class ChatArtifactHighlightedText: @unchecked Sendable {
    let value: NSAttributedString

    init(_ value: NSAttributedString) {
        self.value = NSAttributedString(attributedString: value)
    }
}
