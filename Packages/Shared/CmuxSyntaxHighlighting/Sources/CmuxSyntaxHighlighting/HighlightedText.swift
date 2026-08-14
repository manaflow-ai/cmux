import Foundation

/// Immutable attributed-string snapshot produced by a highlighting engine.
///
/// SAFETY: `value` is copied into an immutable `NSAttributedString` before
/// transfer and is only read after the producing actor has returned it.
public final class HighlightedText: @unchecked Sendable {
    /// Token-colored document. Fonts may still need normalization by the view.
    public let value: NSAttributedString

    /// Copies `value` so the producer can drop its mutable storage.
    public init(_ value: NSAttributedString) {
        self.value = NSAttributedString(attributedString: value)
    }

    /// Distinct foreground colors in `value`. Used by tests to prove tokens exist.
    public var distinctForegroundColorCount: Int {
        var colors: Set<String> = []
        let full = NSRange(location: 0, length: value.length)
        value.enumerateAttribute(.foregroundColor, in: full, options: []) { attribute, _, _ in
            guard let attribute else { return }
            colors.insert(String(describing: attribute))
        }
        return colors.count
    }
}
