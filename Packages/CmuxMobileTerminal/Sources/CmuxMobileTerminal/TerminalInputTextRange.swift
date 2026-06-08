import UIKit

/// An opaque text range for the terminal input view's hand-rolled
/// ``UITextInput`` conformance.
///
/// Like ``TerminalInputTextPosition``, this carries no real document offsets.
/// ``TerminalInputTextView`` keeps two long-lived range sentinels — one
/// identifying the IME marked-text region, one identifying the (always empty)
/// selection — and returns the matching sentinel from `markedTextRange` /
/// `selectedTextRange`. UIKit compares ranges by object identity here, so the
/// view can answer `textInRange:` by checking which sentinel it was handed
/// rather than by indexing a buffer it does not keep.
final class TerminalInputTextRange: UITextRange {
    private let position = TerminalInputTextPosition()

    /// The start of the range. Both ends return the same sentinel position
    /// because the range addresses no real document span; callers only use it
    /// for identity comparison, never to compute offsets.
    override var start: UITextPosition { position }

    /// The end of the range. Returns the same sentinel as ``start`` (see the
    /// note there): the range has no measurable length.
    override var end: UITextPosition { position }

    /// Always reports empty. The view never holds a non-empty selection, and the
    /// marked-text contents are tracked out of band by the view, not via a
    /// measurable range here.
    override var isEmpty: Bool { true }
}
