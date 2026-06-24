#if canImport(UIKit)
import UIKit

/// A `UITextView` that grows with its content up to a cap, then scrolls. It
/// has an intrinsic content size only while scrolling is disabled, which is the
/// mechanism that lets Auto Layout drive the composer height (and, through the
/// accessory's `intrinsicContentSize`, the keyboard region height).
final class GrowingTextView: UITextView {
    var minHeight: CGFloat = 36
    var maxHeight: CGFloat = 140

    /// Called whenever the resolved height changes so the owner can animate
    /// the height constraint and refresh the accessory's intrinsic size.
    var onHeightChange: ((CGFloat) -> Void)?

    private var lastReportedHeight: CGFloat = 0

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isScrollEnabled = false
        backgroundColor = .clear
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        let fitting = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        let result = GrowingTextHeightSolver.solve(
            fittingHeight: fitting,
            minHeight: minHeight,
            maxHeight: maxHeight
        )
        if isScrollEnabled != result.scrollEnabled { isScrollEnabled = result.scrollEnabled }
        if abs(result.height - lastReportedHeight) > 0.5 {
            lastReportedHeight = result.height
            // Defer out of the layout pass that asked for the size.
            DispatchQueue.main.async { [weak self] in self?.onHeightChange?(result.height) }
        }
        return CGSize(width: UIView.noIntrinsicMetric, height: result.height)
    }

    /// The currently resolved (clamped) height; exposed for the measurement probe.
    var resolvedHeight: CGFloat { lastReportedHeight }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Width changes (rotation, split view) change wrap, so re-evaluate.
        invalidateIntrinsicContentSize()
    }
}
#endif
