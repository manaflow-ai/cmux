#if os(iOS)
import SwiftUI
import UIKit

/// Owns the task composer's scroll geometry and the fixed controls that flank
/// its horizontally scrolling pills, following the terminal accessory bar's
/// bounded viewport layout.
@MainActor
final class TaskComposerPillBarViewController<Leading: View, Pills: View, Trailing: View>: UIViewController {
    private let scrollView = TaskComposerEdgeFadeScrollView()
    private let leadingHost: UIHostingController<Leading>
    private let pillsHost: UIHostingController<Pills>
    private let trailingHost: UIHostingController<Trailing>
    /// Keeps the viewport flush with each fixed control, like the terminal
    /// accessory row. The visual breathing room lives inside the scroll view,
    /// so the edge fade starts at the adjacent button instead of after a hard
    /// gap.
    private let scrollContentInset: CGFloat = 8

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
        view.addSubview(leadingHost.view)
        leadingHost.didMove(toParent: self)

        addChild(trailingHost)
        view.addSubview(trailingHost.view)
        trailingHost.didMove(toParent: self)

        configureHostingView(pillsHost.view)
        configureHostingView(leadingHost.view)
        configureHostingView(trailingHost.view)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Keep the scroll viewport flush between the fixed controls. The
            // pills never render underneath either control, and the inset
            // below supplies the visual gap inside the fade band.
            scrollView.leadingAnchor.constraint(equalTo: leadingHost.view.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingHost.view.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            pillsHost.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            pillsHost.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            pillsHost.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            pillsHost.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            pillsHost.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            leadingHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leadingHost.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            trailingHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            trailingHost.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        // Match the terminal accessory's geometry: the scroll frame reaches
        // the adjacent control, while the inset carries the inter-control gap
        // and lets the mask begin fading at that control's edge. Starting at
        // the negative inset keeps the first pill at the same visual position
        // when the row is at rest.
        scrollView.contentInset = UIEdgeInsets(
            top: 0,
            left: scrollContentInset,
            bottom: 0,
            right: scrollContentInset
        )
        scrollView.horizontalScrollIndicatorInsets = scrollView.contentInset
        scrollView.contentOffset = CGPoint(x: -scrollContentInset, y: 0)
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
        hostedView.setContentHuggingPriority(.required, for: .horizontal)
        hostedView.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
}
#endif
