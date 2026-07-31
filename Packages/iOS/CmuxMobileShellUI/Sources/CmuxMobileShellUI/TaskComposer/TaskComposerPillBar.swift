#if os(iOS)
import SwiftUI
import UIKit

/// UIKit host for the composer's bottom control row: a horizontal
/// `UIScrollView` of pills whose leading/trailing button clusters float above
/// the scrolling content. On iOS 26 each cluster carries a
/// `UIScrollEdgeElementContainerInteraction`, so the system renders its real
/// scroll edge effect (progressive blur + fade) beneath the buttons as pills
/// pass under them — SwiftUI's `scrollEdgeEffectStyle` cannot attach that
/// effect to arbitrary floating elements. Pre-26 the clusters get an opaque
/// background instead.
struct TaskComposerPillBar<Leading: View, Pills: View, Trailing: View>: UIViewRepresentable {
    let leading: Leading
    let pills: Pills
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder pills: () -> Pills,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.pills = pills()
        self.trailing = trailing()
    }

    func makeUIView(context: Context) -> TaskComposerPillBarView {
        TaskComposerPillBarView(
            leading: AnyView(leading),
            pills: AnyView(pills),
            trailing: AnyView(trailing)
        )
    }

    func updateUIView(_ view: TaskComposerPillBarView, context: Context) {
        view.update(
            leading: AnyView(leading),
            pills: AnyView(pills),
            trailing: AnyView(trailing)
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: TaskComposerPillBarView,
        context: Context
    ) -> CGSize {
        CGSize(width: proposal.width ?? UIView.noIntrinsicMetric, height: 44)
    }
}

/// The concrete bar: full-width scroll view underneath, button clusters on top.
final class TaskComposerPillBarView: UIView {
    private let scrollView = UIScrollView()
    private let pillsHost: UIHostingController<AnyView>
    private let leadingHost: UIHostingController<AnyView>
    private let trailingHost: UIHostingController<AnyView>
    /// Gap between a button cluster and the resting pill content.
    private let clusterGap: CGFloat = 10

    init(leading: AnyView, pills: AnyView, trailing: AnyView) {
        pillsHost = Self.host(pills)
        leadingHost = Self.host(leading)
        trailingHost = Self.host(trailing)
        super.init(frame: .zero)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.clipsToBounds = false

        addSubview(scrollView)
        scrollView.addSubview(pillsHost.view)
        addSubview(leadingHost.view)
        addSubview(trailingHost.view)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        pillsHost.view.translatesAutoresizingMaskIntoConstraints = false
        leadingHost.view.translatesAutoresizingMaskIntoConstraints = false
        trailingHost.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

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

            leadingHost.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingHost.view.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingHost.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingHost.view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if #available(iOS 26.0, *) {
            let leadingInteraction = UIScrollEdgeElementContainerInteraction()
            leadingInteraction.scrollView = scrollView
            leadingInteraction.edge = .left
            leadingHost.view.addInteraction(leadingInteraction)

            let trailingInteraction = UIScrollEdgeElementContainerInteraction()
            trailingInteraction.scrollView = scrollView
            trailingInteraction.edge = .right
            trailingHost.view.addInteraction(trailingInteraction)
        } else {
            leadingHost.view.backgroundColor = .systemBackground
            trailingHost.view.backgroundColor = .systemBackground
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    func update(leading: AnyView, pills: AnyView, trailing: AnyView) {
        leadingHost.rootView = leading
        pillsHost.rootView = pills
        trailingHost.rootView = trailing
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Rest the pills between the clusters while letting them scroll
        // beneath both; cluster widths change (the attachment button is
        // capability-gated), so track them each pass.
        let leadingWidth = leadingHost.view.bounds.width
        let trailingWidth = trailingHost.view.bounds.width
        let insets = UIEdgeInsets(
            top: 0,
            left: leadingWidth + clusterGap,
            bottom: 0,
            right: trailingWidth + clusterGap
        )
        if scrollView.contentInset != insets {
            let wasAtRest = scrollView.contentOffset.x <= -scrollView.contentInset.left
            scrollView.contentInset = insets
            if wasAtRest {
                scrollView.contentOffset = CGPoint(x: -insets.left, y: 0)
            }
        }
    }

    private static func host(_ view: AnyView) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: view)
        controller.view.backgroundColor = .clear
        controller.sizingOptions = .intrinsicContentSize
        return controller
    }
}
#endif
