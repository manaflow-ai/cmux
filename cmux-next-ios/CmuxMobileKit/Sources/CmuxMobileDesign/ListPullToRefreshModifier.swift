#if os(iOS)
import SwiftUI
import UIKit

public extension View {
    /// Workspaces' pull to refresh (``ListPullToRefresh``, the wheel that stays in the list under
    /// the pull-down search field) on a SwiftUI `List`, so Home's list refreshes exactly as the
    /// Workspaces list does. `nil` leaves the list without one. Put it on the `List` itself, as
    /// `cmuxMobilePullDownSearch`: it finds the screen's list the same way.
    func cmuxMobileListPullToRefresh(_ action: (() async -> Void)?) -> some View {
        background { ListPullToRefreshProbe(action: action) }
    }
}

/// Finds the `List`'s collection view and drives a ``ListPullToRefresh`` on it. A SwiftUI
/// `List` keeps its collection view's delegate, so the calls Workspaces' collection makes
/// from its delegate come from the list's offset (`scrolled`), its pan ending
/// (`willEndDragging`: the pan's own end runs first, so the bounce is already set up) and
/// the list coming to rest (`endedDecelerating`).
struct ListPullToRefreshProbe: UIViewRepresentable {
    let action: (() async -> Void)?

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ uiView: Probe, context: Context) {
        uiView.action = action
        uiView.attachIfNeeded()
    }

    static func dismantleUIView(_ uiView: Probe, coordinator: ()) {
        uiView.detach()
    }

    final class Probe: UIView {
        var action: (() async -> Void)?
        private weak var scrollView: UIScrollView?
        private var control: ListPullToRefresh?
        private var offsetObservation: NSKeyValueObservation?
        /// A check for the list coming to rest is queued.
        private var awaitingRest = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // The list is in the hierarchy one pass after this probe.
            DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
        }

        func attachIfNeeded() {
            guard action != nil else { return detach() }
            guard control == nil, window != nil, let controller = owningController(),
                  let scroll = Self.firstCollectionView(in: controller.view) else { return }
            scrollView = scroll
            control = ListPullToRefresh(scrollView: scroll) { [weak self] in
                await self?.action?()
            }
            offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scrolled() }
            }
            scroll.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
        }

        func detach() {
            offsetObservation?.invalidate()
            offsetObservation = nil
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
            control?.detach()
            control = nil
            scrollView = nil
        }

        private func scrolled() {
            guard let control, let scrollView else { return }
            control.scrolled()
            if !scrollView.isDragging, scrollView.isDecelerating { awaitRest() }
        }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .ended || pan.state == .cancelled || pan.state == .failed,
                  let control, let scrollView else { return }
            var target = scrollView.contentOffset
            control.willEndDragging(targetContentOffset: &target)
            awaitRest()
        }

        /// `scrollViewDidEndDecelerating`, which the list's own delegate gets: checks each
        /// frame-ish until the list stops moving.
        private func awaitRest() {
            guard !awaitingRest else { return }
            awaitingRest = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.awaitingRest = false
                guard let scrollView = self.scrollView else { return }
                if scrollView.isDragging { return }
                if scrollView.isDecelerating { return self.awaitRest() }
                self.control?.endedDecelerating()
            }
        }

        private func owningController() -> UIViewController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller }
                responder = next
            }
            return nil
        }

        private static func firstCollectionView(in view: UIView) -> UICollectionView? {
            for subview in view.subviews {
                if let match = subview as? UICollectionView { return match }
                if let match = firstCollectionView(in: subview) { return match }
            }
            return nil
        }
    }
}
#endif
