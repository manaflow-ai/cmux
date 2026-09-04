#if os(iOS)
import SwiftUI
import UIKit

/// Owns the task composer's scroll geometry and the fixed controls that
/// underlap its horizontally scrolling pills.
@MainActor
final class TaskComposerPillBarViewController<Leading: View, Pills: View, Trailing: View>: UIViewController {
    private let scrollView = TaskComposerEdgeFadeScrollView()
    private let leadingContainer = PassthroughContainerView()
    private let trailingContainer = PassthroughContainerView()
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
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.isDirectionalLockEnabled = true
        scrollView.accessibilityIdentifier = "MobileTaskComposerPillScroller"

        addChild(pillsHost)
        scrollView.addSubview(pillsHost.view)
        pillsHost.didMove(toParent: self)

        view.addSubview(scrollView)

        addChild(leadingHost)
        leadingContainer.addSubview(leadingHost.view)
        view.addSubview(leadingContainer)
        leadingHost.didMove(toParent: self)

        addChild(trailingHost)
        trailingContainer.addSubview(trailingHost.view)
        view.addSubview(trailingContainer)
        trailingHost.didMove(toParent: self)

        configureHostingView(pillsHost.view)
        configureHostingView(leadingHost.view)
        configureHostingView(trailingHost.view)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        leadingContainer.translatesAutoresizingMaskIntoConstraints = false
        trailingContainer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            pillsHost.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            pillsHost.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            pillsHost.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            pillsHost.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            pillsHost.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            leadingContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leadingContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            leadingContainer.topAnchor.constraint(equalTo: view.topAnchor),
            leadingContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leadingHost.view.leadingAnchor.constraint(equalTo: leadingContainer.leadingAnchor),
            leadingHost.view.centerYAnchor.constraint(equalTo: leadingContainer.centerYAnchor),

            trailingContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            trailingContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trailingContainer.topAnchor.constraint(equalTo: view.topAnchor),
            trailingContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            trailingHost.view.trailingAnchor.constraint(equalTo: trailingContainer.trailingAnchor),
            trailingHost.view.centerYAnchor.constraint(equalTo: trailingContainer.centerYAnchor),
        ])
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

        let wasAtLeadingRest = scrollView.contentOffset.x <= -scrollView.contentInset.left + 1
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
}

/// Lets full-width fixed-control containers overlap the scroll view without
/// stealing touches from the hosted SwiftUI controls.
private final class PassthroughContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        return hitView === self ? nil : hitView
    }
}
#endif
