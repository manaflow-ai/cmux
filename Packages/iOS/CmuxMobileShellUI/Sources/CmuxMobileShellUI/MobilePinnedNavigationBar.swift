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
    /// The stand-in cannot host the iOS 26 scroll edge effect for the
    /// terminal's under-bar band: UIKit renders that effect on the tracked
    /// scroll view's own content subtree, and the terminal's pixels live in
    /// the Ghostty render layer outside any scroll view (verified on-device;
    /// an on-window frozen mid-scroll stand-in overlaying the band renders
    /// nothing). The band's fade is instead screen-anchored chrome in
    /// `GhosttySurfaceHostView`.
    ///
    /// On iOS 27 the native opt-out is applied as well once an Xcode 27
    /// toolchain builds this target.
    @ViewBuilder
    func mobilePinnedNavigationBar() -> some View {
        #if canImport(UIKit)
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            background(PinnedNavigationBarApplier())
                .toolbarMinimizeBehavior(.never, for: .navigationBar)
        } else {
            background(PinnedNavigationBarApplier())
        }
        #else
        background(PinnedNavigationBarApplier())
        #endif
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
private struct PinnedNavigationBarApplier: UIViewRepresentable {
    func makeUIView(context: Context) -> PinnedNavigationBarProbeView {
        let view = PinnedNavigationBarProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: PinnedNavigationBarProbeView, context: Context) {
        view.applyIfNeeded()
    }

    static func dismantleUIView(_ view: PinnedNavigationBarProbeView, coordinator: ()) {
        view.clearAssociation()
    }
}

final class PinnedNavigationBarProbeView: UIView {
    /// The stand-in the bar tracks instead of the real content: zero content,
    /// scrolling disabled, so the bar's scroll edge never moves.
    private let anchorScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.isScrollEnabled = false
        return scrollView
    }()
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
