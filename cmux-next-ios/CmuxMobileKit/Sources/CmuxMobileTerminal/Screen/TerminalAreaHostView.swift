#if os(iOS)
import UIKit

/// A full-screen app's area (`TerminalViewController.tuiHost`): the grid,
/// and while the Mac redraws, its held still. It clips what it holds to its
/// own height, so rows the surface shifts above it (the cursor row kept on
/// screen while a taller grid is fed behind the held still) never show in
/// the sub-row band between the toolbar and row 1. Sideways it lets the
/// surface reach `overhang` points past each edge (a panned or wider grid,
/// and the side padding; the page's clip bounds it there).
final class TerminalAreaHostView: UIView {
    var overhang: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    private let clip = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clip.backgroundColor = UIColor.black.cgColor
        layer.mask = clip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = bounds.insetBy(dx: -overhang, dy: 0)
        guard clip.frame != frame else { return }
        // The mask follows the area at once, with no implicit animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = frame
        CATransaction.commit()
    }
}
#endif
