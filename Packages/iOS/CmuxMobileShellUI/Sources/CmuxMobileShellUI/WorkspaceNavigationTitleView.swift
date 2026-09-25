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
    // rendered capsule the same 36-point chrome and compact leading/trailing
    // treatment as the original toolbar.
    private static let capsuleLeadingInset: CGFloat = 4
    private static let capsuleTrailingInset: CGFloat = 10
    private static let contentHorizontalInset: CGFloat = 6
    private static let preferredContentWidth: CGFloat = 192

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
            y: 4,
            width: max(0, bounds.width - Self.capsuleLeadingInset - Self.capsuleTrailingInset),
            height: min(36, bounds.height)
        )
        if #unavailable(iOS 26.0) {
            capsule.layer.cornerRadius = bounds.height / 2
        }
        let inset = min(Self.contentHorizontalInset, capsule.bounds.width / 2)
        contentView.frame = capsule.bounds.insetBy(dx: inset, dy: 0)
    }
}
#endif
