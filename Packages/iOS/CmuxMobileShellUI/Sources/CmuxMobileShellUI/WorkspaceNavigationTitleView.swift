#if os(iOS)
import SwiftUI
import UIKit

/// UINavigationBar assigns the title's frame between its button groups.
/// This view insets its hosted menu by the base toolbar's glass padding.
/// There is deliberately no minimum title width or screen/size-class estimate.
@MainActor
final class WorkspaceNavigationTitleView: UIView {
    private let contentView: UIView & UIContentView
    private let capsule: UIVisualEffectView
    // UINavigationItem.titleView keeps a little more layout width than the
    // compact SwiftUI title capsule. Keep that native slot, but give the
    // rendered capsule the same native 44-point title chrome and compact
    // leading/trailing treatment as the original toolbar. The hosted label
    // remains a centered 36-point content slot inside that chrome.
    private static let capsuleLeadingInset: CGFloat = 0
    private static let capsuleTrailingInset: CGFloat = 6
    private static let contentHorizontalInset: CGFloat = 10
    private static let contentHeight: CGFloat = 36
    private static let capsuleHeight: CGFloat = 44
    private static let preferredContentWidth: CGFloat = 200

    init() {
        contentView = UIHostingConfiguration { AnyView(EmptyView()) }.margins(.all, 0).minSize(width: 0, height: 0).makeContentView()
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            capsule = UIVisualEffectView(effect: glass)
        } else {
            capsule = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        }
        super.init(frame: .zero)
        if #available(iOS 26.0, *) {
            capsule.cornerConfiguration = .capsule()
        } else {
            capsule.clipsToBounds = true
        }
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(capsule)
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = true
        capsule.contentView.addSubview(contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func update(content: AnyView) {
        contentView.configuration = UIHostingConfiguration { content }.margins(.all, 0).minSize(width: 0, height: 0)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        let content = contentView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        // Preserve the base title's preferred maximum. This is a presentation
        // preference, not an estimate of available space: the navigation bar
        // can reduce it further to fit its actual button groups.
        return CGSize(
            width: min(Self.preferredContentWidth, max(0, content.width))
                + Self.capsuleLeadingInset + Self.capsuleTrailingInset,
            height: 44
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = CGRect(
            x: Self.capsuleLeadingInset,
            y: 0,
            width: max(0, bounds.width - Self.capsuleLeadingInset - Self.capsuleTrailingInset),
            height: min(Self.capsuleHeight, bounds.height)
        )
        if #unavailable(iOS 26.0) {
            capsule.layer.cornerRadius = capsule.bounds.height / 2
        }
        let inset = min(Self.contentHorizontalInset, capsule.bounds.width / 2)
        let contentHeight = min(Self.contentHeight, capsule.bounds.height)
        contentView.frame = CGRect(
            x: inset,
            y: (capsule.bounds.height - contentHeight) / 2,
            width: max(0, capsule.bounds.width - inset * 2),
            height: contentHeight
        )
    }
}
#endif
