public import AppKit

public extension NSLayoutConstraint.Priority {
    /// The horizontal compression resistance of a label whose container
    /// takes its width from its content: a pill, toast, badge, banner or
    /// floating panel sized by `fittingSize`, or an `NSStackView` row with
    /// only `<=` caps from outside.
    ///
    /// AppKit labels resist at `.defaultLow` (250), the same as a stack
    /// view's hugging. In a content-sized view that tie squeezes the label
    /// to about 4 pt and only the icons and buttons draw (cx-w0p5 toasts,
    /// cx-whr7 browser notice, cx-k9mc audit). Above default-high hugging
    /// (750) and below the required caps, the label keeps its text width and
    /// a cap (a max width, a side inset) still truncates or wraps it.
    ///
    /// A label in a view whose width comes from outside (a table row, a
    /// field pinned at both edges) keeps the low default: there it is the
    /// part that truncates first.
    static let keepsTextWidth = NSLayoutConstraint.Priority(760)
}
