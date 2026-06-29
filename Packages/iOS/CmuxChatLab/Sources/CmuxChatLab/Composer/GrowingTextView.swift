#if canImport(UIKit)
import UIKit

/// A plain `UITextView` configured for composer use: no scrolling while it
/// grows (so its height is driven by an explicit constraint the owner sizes
/// from `GrowingTextHeightSolver`), system body font, content-size adaptive.
///
/// Deliberately has NO `intrinsicContentSize` override: resolving height inside
/// a layout getter (and bouncing through `DispatchQueue`) is a smell. The owner
/// (`ComposerBar`) computes height in `textViewDidChange`/`layoutSubviews` and
/// updates the height constraint directly.
final class GrowingTextView: UITextView {
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
}
#endif
