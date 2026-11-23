#if os(iOS)
import CmuxMobileDesign
import UIKit

/// A stack's fold line (`FeedStacks`): "3 earlier updates" under the newest event of a chat that
/// posted several in a row. UIKit views only, placed at a `FeedRowLayout.Fold`'s frames like every
/// Feed row (verify/feed-perf-20261022.md). The whole 44 pt line is the button; its chevron turns
/// down while the older events show.
final class FeedFoldCell: UITableViewCell {
    static let reuseID = "FeedFoldCell"

    /// The fold line was tapped: its row id.
    var onToggle: ((String) -> Void)?
    private var id = ""
    private var expanded = false
    private let button = FeedFoldButton()
    private let title = UILabel()
    private let chevron = UIImageView()
    private let divider = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .cmuxMobileBackground
        contentView.clipsToBounds = true
        contentView.addSubview(button)
        button.addAction(UIAction { [weak self] _ in self.map { $0.onToggle?($0.id) } }, for: .touchUpInside)
        title.isUserInteractionEnabled = false
        title.numberOfLines = 1
        button.addSubview(title)
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        chevron.contentMode = .center
        chevron.tintColor = .tertiaryLabel
        chevron.isUserInteractionEnabled = false
        button.addSubview(chevron)
        divider.backgroundColor = .separator
        contentView.addSubview(divider)
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ layout: FeedRowLayout) {
        guard let fold = layout.fold else { return }
        let width = CGFloat(layout.key.width)
        // The same line toggled (not a reused cell): the chevron turns, unless motion is reduced.
        let turns = id == layout.key.item.id && expanded != fold.expanded && window != nil && !UIAccessibility.isReduceMotionEnabled
        id = layout.key.item.id
        expanded = fold.expanded
        accessibilityIdentifier = id
        button.frame = CGRect(x: 0, y: 0, width: width, height: layout.dividerY)
        title.attributedText = fold.title
        title.frame = fold.titleFrame
        chevron.bounds = CGRect(origin: .zero, size: fold.chevron.size)
        chevron.center = CGPoint(x: fold.chevron.midX, y: fold.chevron.midY)
        let transform: CGAffineTransform = fold.expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        if turns {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) { self.chevron.transform = transform }
        } else {
            UIView.performWithoutAnimation { chevron.transform = transform }
        }
        divider.frame = CGRect(x: layout.column.minX, y: layout.dividerY, width: width - layout.column.minX,
                               height: layout.height - layout.dividerY)
        button.accessibilityIdentifier = "feed.fold"
        button.accessibilityLabel = fold.spoken
        button.accessibilityValue = fold.expanded ? "Expanded" : "Collapsed"
    }
}

/// The fold line's press: the fill only (design/pressed-state.md), as the rows' capsules.
private final class FeedFoldButton: UIControl {
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .cmuxMobileFillPressed : .clear }
    }
}
#endif
