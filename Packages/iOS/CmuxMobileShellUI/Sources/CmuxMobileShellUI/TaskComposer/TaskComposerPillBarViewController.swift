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
    private let fixedControlGap: CGFloat = 8

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
            // Keep the scroll viewport between the fixed controls. The pills
            // never render underneath either control, so the edge mask fades
            // them at the actual viewport boundary instead of hiding overlap.
            scrollView.leadingAnchor.constraint(equalTo: leadingHost.view.trailingAnchor, constant: fixedControlGap),
            scrollView.trailingAnchor.constraint(equalTo: trailingHost.view.leadingAnchor, constant: -fixedControlGap),
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

        // Unlike the terminal bar, this row has fixed controls on both sides,
        // so there is no content inset to carry a visual gap or allow overlap.
        // The viewport itself supplies the clipping boundary for the mask.
        scrollView.contentInset = .zero
        scrollView.horizontalScrollIndicatorInsets = .zero
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
