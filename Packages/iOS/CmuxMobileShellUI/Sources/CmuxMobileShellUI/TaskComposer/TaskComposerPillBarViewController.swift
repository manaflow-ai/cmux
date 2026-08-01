#if os(iOS)
import SwiftUI
import UIKit

/// Owns the native scroll view and shape-aware edge-effect containers.
@MainActor
final class TaskComposerPillBarViewController<
    Leading: View,
    Pills: View,
    Trailing: View
>: UIViewController {
    private let scrollView = UIScrollView()
    private let leadingEffectContainer = PassthroughContainerView()
    private let trailingEffectContainer = PassthroughContainerView()
    private let leadingEffectShape = EdgeEffectGlassView()
    private let trailingEffectShape = EdgeEffectGlassView()
    private let leadingHost: UIHostingController<Leading>
    private let pillsHost: UIHostingController<Pills>
    private let trailingHost: UIHostingController<Trailing>
    private let clusterGap: CGFloat = 10
    private let fixedClusterHorizontalPadding: CGFloat = 16
    private let fixedControlVisualInset: CGFloat = 3

    init(leading: Leading, pills: Pills, trailing: Trailing) {
        leadingHost = UIHostingController(rootView: leading)
        pillsHost = UIHostingController(rootView: pills)
        trailingHost = UIHostingController(rootView: trailing)
        leadingHost.sizingOptions = .intrinsicContentSize
        pillsHost.sizingOptions = .intrinsicContentSize
        trailingHost.sizingOptions = .intrinsicContentSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.isDirectionalLockEnabled = true
        scrollView.accessibilityIdentifier = "MobileTaskComposerPillScroller"

        addChild(pillsHost)
        scrollView.addSubview(pillsHost.view)
        pillsHost.didMove(toParent: self)

        view.addSubview(scrollView)
        view.addSubview(leadingEffectContainer)
        view.addSubview(trailingEffectContainer)

        addChild(leadingHost)
        leadingEffectContainer.addSubview(leadingEffectShape)
        leadingEffectContainer.addSubview(leadingHost.view)
        leadingHost.didMove(toParent: self)

        addChild(trailingHost)
        trailingEffectContainer.addSubview(trailingEffectShape)
        trailingEffectContainer.addSubview(trailingHost.view)
        trailingHost.didMove(toParent: self)

        configureHostingView(pillsHost.view)
        configureHostingView(leadingHost.view)
        configureHostingView(trailingHost.view)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        leadingEffectContainer.translatesAutoresizingMaskIntoConstraints = false
        trailingEffectContainer.translatesAutoresizingMaskIntoConstraints = false
        leadingEffectShape.translatesAutoresizingMaskIntoConstraints = false
        trailingEffectShape.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            pillsHost.view.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor
            ),
            pillsHost.view.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor
            ),
            pillsHost.view.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor
            ),
            pillsHost.view.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor
            ),
            pillsHost.view.heightAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.heightAnchor
            ),

            leadingEffectContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leadingEffectContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            leadingEffectContainer.topAnchor.constraint(equalTo: view.topAnchor),
            leadingEffectContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leadingHost.view.leadingAnchor.constraint(equalTo: leadingEffectContainer.leadingAnchor),
            leadingHost.view.centerYAnchor.constraint(equalTo: leadingEffectContainer.centerYAnchor),
            leadingEffectShape.leadingAnchor.constraint(
                equalTo: leadingHost.view.leadingAnchor,
                constant: fixedClusterHorizontalPadding + fixedControlVisualInset
            ),
            leadingEffectShape.trailingAnchor.constraint(
                equalTo: leadingHost.view.trailingAnchor,
                constant: -fixedControlVisualInset
            ),
            leadingEffectShape.topAnchor.constraint(
                equalTo: leadingHost.view.topAnchor,
                constant: fixedControlVisualInset
            ),
            leadingEffectShape.bottomAnchor.constraint(
                equalTo: leadingHost.view.bottomAnchor,
                constant: -fixedControlVisualInset
            ),

            trailingEffectContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trailingEffectContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            trailingEffectContainer.topAnchor.constraint(equalTo: view.topAnchor),
            trailingEffectContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            trailingHost.view.trailingAnchor.constraint(equalTo: trailingEffectContainer.trailingAnchor),
            trailingHost.view.centerYAnchor.constraint(equalTo: trailingEffectContainer.centerYAnchor),
            trailingEffectShape.leadingAnchor.constraint(
                equalTo: trailingHost.view.leadingAnchor,
                constant: fixedControlVisualInset
            ),
            trailingEffectShape.trailingAnchor.constraint(
                equalTo: trailingHost.view.trailingAnchor,
                constant: -(fixedClusterHorizontalPadding + fixedControlVisualInset)
            ),
            trailingEffectShape.topAnchor.constraint(
                equalTo: trailingHost.view.topAnchor,
                constant: fixedControlVisualInset
            ),
            trailingEffectShape.bottomAnchor.constraint(
                equalTo: trailingHost.view.bottomAnchor,
                constant: -fixedControlVisualInset
            ),
        ])

        configureScrollEdgeEffects()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let insets = UIEdgeInsets(
            top: 0,
            left: leadingHost.view.bounds.width + clusterGap,
            bottom: 0,
            right: trailingHost.view.bounds.width + clusterGap
        )
        guard scrollView.contentInset != insets else { return }

        let wasAtLeadingRest = scrollView.contentOffset.x <= -scrollView.contentInset.left
        scrollView.contentInset = insets
        scrollView.horizontalScrollIndicatorInsets = insets
        if wasAtLeadingRest {
            scrollView.contentOffset = CGPoint(x: -insets.left, y: 0)
        }
    }

    func update(leading: Leading, pills: Pills, trailing: Trailing) {
        leadingHost.rootView = leading
        pillsHost.rootView = pills
        trailingHost.rootView = trailing
        view.setNeedsLayout()
    }

    private func configureHostingView(_ hostedView: UIView) {
        hostedView.backgroundColor = .clear
        hostedView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureScrollEdgeEffects() {
        guard #available(iOS 26.0, *) else {
            leadingHost.view.backgroundColor = .systemBackground
            trailingHost.view.backgroundColor = .systemBackground
            return
        }

        scrollView.leftEdgeEffect.style = .automatic
        scrollView.rightEdgeEffect.style = .automatic

        let leadingInteraction = UIScrollEdgeElementContainerInteraction()
        leadingInteraction.scrollView = scrollView
        leadingInteraction.edge = .left
        leadingEffectContainer.addInteraction(leadingInteraction)

        let trailingInteraction = UIScrollEdgeElementContainerInteraction()
        trailingInteraction.scrollView = scrollView
        trailingInteraction.edge = .right
        trailingEffectContainer.addInteraction(trailingInteraction)
    }
}

/// Lets the two full-width edge-effect containers overlap without blocking
/// the SwiftUI controls hosted inside either one.
private final class PassthroughContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        return hitView === self ? nil : hitView
    }
}

/// UIKit's scroll-edge interaction discovers glass views, while SwiftUI's
/// hosting view does not expose its rendered controls as UIKit descendants.
/// This native glass sibling supplies the fixed cluster's geometry while the
/// SwiftUI host remains the single action and accessibility path.
private final class EdgeEffectGlassView: UIVisualEffectView {
    init() {
        super.init(effect: nil)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect(style: .regular)
            cornerConfiguration = .capsule()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
#endif
