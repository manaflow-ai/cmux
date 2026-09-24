#if os(iOS)
import SwiftUI
import UIKit

/// Custom bar content follows UIKit's margins, including the glass padding.
/// Its natural width changes with the label instead of a per-control estimate.
@MainActor
final class WorkspaceNavigationControlView: UIView {
    enum Placement {
        case leading
        case trailing
    }

    private let contentView: UIView & UIContentView
    private var width: NSLayoutConstraint?
    private var placement: Placement = .leading
    private var isLandscape = false
    private var widthAdjustment: CGFloat = 0
    private var visualOffset: CGFloat = 0

    init(content: AnyView) {
        contentView = UIHostingConfiguration { content.ignoresSafeArea() }.margins(.all, 0).minSize(width: 0, height: 0).makeContentView()
        super.init(frame: .zero)
        layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        // The bar already places items around the device's safe area. Adding
        // it again here enlarges the end items by 17 points in landscape.
        insetsLayoutMarginsFromSafeArea = false
        translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            contentView.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 36),
        ])
        width = widthAnchor.constraint(equalToConstant: intrinsicContentSize.width)
        width?.isActive = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        let contentSize = contentView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: contentSize.width + layoutMargins.left + layoutMargins.right, height: 36)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }

    override func layoutMarginsDidChange() {
        super.layoutMarginsDidChange()
        refreshContentSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.layer.setAffineTransform(CGAffineTransform(translationX: visualOffset, y: 0))
    }

    func update(content: AnyView) {
        contentView.configuration = UIHostingConfiguration { content.ignoresSafeArea() }.margins(.all, 0).minSize(width: 0, height: 0)
        refreshContentSize()
    }

    func update(placement: Placement, isLandscape: Bool, visualOffset: CGFloat = 0) {
        let effectiveOffset = isLandscape ? visualOffset : 0
        guard self.placement != placement || self.isLandscape != isLandscape || self.visualOffset != effectiveOffset else { return }
        self.placement = placement
        self.isLandscape = isLandscape
        self.visualOffset = effectiveOffset
        widthAdjustment = placement == .trailing && isLandscape ? -3 : 0
        contentView.layer.setAffineTransform(.identity)
        let leading: CGFloat = placement == .trailing && isLandscape ? 4.5 : 8
        let trailing: CGFloat = placement == .leading && isLandscape ? -5 : 8
        layoutMargins = UIEdgeInsets(top: 8, left: leading, bottom: 8, right: trailing)
        refreshContentSize()
    }

    private func refreshContentSize() {
        contentView.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        width?.constant = max(0, intrinsicContentSize.width + widthAdjustment)
    }
}
#endif
