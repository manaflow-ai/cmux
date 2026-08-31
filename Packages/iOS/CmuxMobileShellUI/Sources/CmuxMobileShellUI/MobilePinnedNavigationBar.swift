import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// Keeps the navigation bar fully expanded over scrollable content.
    ///
    /// iOS 26 minimizes the navigation bar into a floating overflow pill when
    /// the content under it scrolls (Safari-style), which hides the back
    /// button, the workspace title, and the trailing controls behind a "…"
    /// menu on the browser and chat surfaces. The SwiftUI opt-out
    /// (`toolbarMinimizeBehavior(.never)`) does not exist in the iOS 26 SDK,
    /// and UIKit's 26 SDK only exposes a minimize behavior for the tab bar.
    /// The bar's scroll linkage does have a public control: the view
    /// controller's top-edge content scroll view (iOS 15+), which UIKit
    /// otherwise discovers automatically (the browser pane's web view).
    /// Re-pointing that association at a static, never-scrolling stand-in
    /// decouples the bar from the content, so it stays expanded exactly like
    /// the terminal surface, where no system scroll view exists to discover.
    ///
    /// On iOS 27 the native opt-out is applied as well once an Xcode 27
    /// toolchain builds this target.
    ///
    /// `scrolledUnderContent` selects the stand-in's reported scroll state.
    /// `false` (the default) keeps the historical contract: zero content at
    /// rest, so the bar renders no scroll edge treatment. `true` reports a
    /// tall content frozen mid-scroll, so the bar renders its scroll edge
    /// effect (the iOS 26 progressive blur) over whatever visually underlaps
    /// it — the terminal's scroll-edge band — while the frozen offset still
    /// never emits the scroll deltas that would minimize the bar. The
    /// association stays decoupled from the real content either way.
    @ViewBuilder
    func mobilePinnedNavigationBar(scrolledUnderContent: Bool = false) -> some View {
        #if canImport(UIKit)
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            mobilePinnedNavigationBarProbe(scrolledUnderContent: scrolledUnderContent)
                .toolbarMinimizeBehavior(.never, for: .navigationBar)
        } else {
            mobilePinnedNavigationBarProbe(scrolledUnderContent: scrolledUnderContent)
        }
        #else
        mobilePinnedNavigationBarProbe(scrolledUnderContent: scrolledUnderContent)
        #endif
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
private extension View {
    /// The probe rides ON TOP of the content and underlaps the bar: the
    /// scroll edge effect renders inside the tracked scroll view's own
    /// hierarchy as a backdrop treatment, so it must sit in front of the
    /// content it blurs (a background-hosted stand-in blurs only what's
    /// behind the content) and must geometrically overlap the bar region.
    /// The probe is empty, transparent, and hit-test-inert either way.
    func mobilePinnedNavigationBarProbe(scrolledUnderContent: Bool) -> some View {
        overlay {
            PinnedNavigationBarApplier(scrolledUnderContent: scrolledUnderContent)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
        }
    }
}
#endif

#if canImport(UIKit)
private struct PinnedNavigationBarApplier: UIViewRepresentable {
    var scrolledUnderContent: Bool = false

    func makeUIView(context: Context) -> PinnedNavigationBarProbeView {
        let view = PinnedNavigationBarProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.setScrolledUnderContent(scrolledUnderContent)
        return view
    }

    func updateUIView(_ view: PinnedNavigationBarProbeView, context: Context) {
        view.setScrolledUnderContent(scrolledUnderContent)
        view.applyIfNeeded()
    }

    static func dismantleUIView(_ view: PinnedNavigationBarProbeView, coordinator: ()) {
        view.clearAssociation()
    }
}

final class PinnedNavigationBarProbeView: UIView {
    /// The stand-in the bar tracks instead of the real content: scrolling
    /// disabled, so the bar's scroll edge never moves. At rest it reports
    /// zero content (no scroll edge treatment); in scrolled-under mode it
    /// reports a tall content frozen mid-scroll so the bar renders its
    /// scroll edge effect over the content that visually underlaps it.
    ///
    /// The stand-in lives IN the hierarchy (a probe-sized, empty, untouchable
    /// subview): UIKit only renders the scroll edge effect for an on-window
    /// content scroll view with real geometry. Empty and non-interactive, it
    /// draws nothing and eats no touches; the effect's blur is a backdrop at
    /// the bar, so it treats whatever actually renders under the bar — the
    /// terminal's overscan band — regardless of this view's z-position.
    private let anchorScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.isScrollEnabled = false
        scrollView.isUserInteractionEnabled = false
        return scrollView
    }()

    /// The mid-scroll pose: any content/offset pair that keeps the offset
    /// strictly inside the scrollable range, so UIKit reads "content under
    /// the bar" without ever seeing a scroll delta.
    private static let scrolledUnderContentHeight: CGFloat = 10_000
    private static let scrolledUnderOffset: CGFloat = 5_000

    private var scrolledUnderContent = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        anchorScrollView.frame = bounds
        anchorScrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(anchorScrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setScrolledUnderContent(_ scrolledUnder: Bool) {
        scrolledUnderContent = scrolledUnder
        applyScrollPose()
    }

    private func applyScrollPose() {
        if scrolledUnderContent {
            let size = CGSize(
                width: max(1, bounds.width),
                height: Self.scrolledUnderContentHeight
            )
            if anchorScrollView.contentSize != size {
                anchorScrollView.contentSize = size
            }
            if anchorScrollView.contentOffset.y != Self.scrolledUnderOffset {
                anchorScrollView.contentOffset = CGPoint(x: 0, y: Self.scrolledUnderOffset)
            }
        } else {
            guard anchorScrollView.contentSize.height != 0 else { return }
            anchorScrollView.contentSize = .zero
            anchorScrollView.contentOffset = .zero
        }
    }
    /// The controller currently pointed at the stand-in, so teardown can
    /// release the association instead of leaving the bar tracking a
    /// deallocated probe's scroll view.
    private weak var appliedTarget: UIViewController?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the frozen pose sized with the probe (content width tracks
        // the bounds; the offset never moves).
        applyScrollPose()
        // Re-assert after layout passes: SwiftUI can re-derive the tracked
        // scroll view for its own containers, and the association resets when
        // the hosting controller re-parents during navigation transitions.
        applyIfNeeded()
    }

    func applyIfNeeded() {
        guard window != nil, let target = barOwningViewController() else { return }
        if target.contentScrollView(for: .top) !== anchorScrollView {
            target.setContentScrollView(anchorScrollView, for: .top)
            appliedTarget = target
        }
    }

    func clearAssociation() {
        guard let target = appliedTarget,
              target.contentScrollView(for: .top) === anchorScrollView
        else { return }
        target.setContentScrollView(nil, for: .top)
        appliedTarget = nil
    }

    /// The pushed screen's view controller: the ancestor whose parent is the
    /// navigation controller (its navigation item drives the bar). Fails
    /// closed when no such ancestor exists (previews, sheets), rather than
    /// re-pointing an unrelated controller's scroll edge.
    private func barOwningViewController() -> UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let viewController = current as? UIViewController,
               viewController.parent is UINavigationController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}
#endif
