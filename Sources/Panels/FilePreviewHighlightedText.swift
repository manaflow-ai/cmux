import Foundation

/// Immutable bridge for an attributed result produced off the main actor.
///
/// SAFETY: `value` is copied into an immutable `NSAttributedString` before transfer
/// and is only read after the producing actor has returned it.
final class FilePreviewHighlightedText: @unchecked Sendable {
    let value: NSAttributedString

    init(_ value: NSAttributedString) {
        self.value = NSAttributedString(attributedString: value)
    }
}
