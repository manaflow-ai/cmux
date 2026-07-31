#if os(iOS)
import SwiftUI
import UIKit

/// Owns the native scroll view and the floating clusters that shape its edge effect.
@MainActor
final class TaskComposerPillBarViewController<
    Leading: View,
    Pills: View,
    Trailing: View
>: UIViewController {
    private let scrollView = UIScrollView()
    private let leadingHost: UIHostingController<Leading>
    private let pillsHost: UIHostingController<Pills>
    private let trailingHost: UIHostingController<Trailing>
    private let clusterGap: CGFloat = 10

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

        addChild(pillsHost)
        scrollView.addSubview(pillsHost.view)
        pillsHost.didMove(toParent: self)

        addChild(leadingHost)
        view.addSubview(leadingHost.view)
        leadingHost.didMove(toParent: self)

        addChild(trailingHost)
        view.addSubview(trailingHost.view)
        trailingHost.didMove(toParent: self)

        view.insertSubview(scrollView, at: 0)
        configureHostingView(pillsHost.view)
        configureHostingView(leadingHost.view)
        configureHostingView(trailingHost.view)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

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

            leadingHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leadingHost.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            trailingHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            trailingHost.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
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

        scrollView.leftEdgeEffect.style = .soft
        scrollView.rightEdgeEffect.style = .soft

        let leadingInteraction = UIScrollEdgeElementContainerInteraction()
        leadingInteraction.scrollView = scrollView
        leadingInteraction.edge = .left
        leadingHost.view.addInteraction(leadingInteraction)

        let trailingInteraction = UIScrollEdgeElementContainerInteraction()
        trailingInteraction.scrollView = scrollView
        trailingInteraction.edge = .right
        trailingHost.view.addInteraction(trailingInteraction)
    }
}
#endif
