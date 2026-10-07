import AppKit
import Foundation

/// The sidebar toggle as a synthetic divider drag.
///
/// cmux already has one place where the terminal live-resizes beautifully:
/// dragging the sidebar's width divider, which feeds real widths through the
/// layout on every pointer tick. The toggle borrows exactly that mechanism:
/// a timer sweeps the REAL `SidebarLayoutModel.width` along an ease curve, so
/// the sidebar collapse, the terminal's live expansion, and every dependent
/// piece of chrome move together through the same proven path. No SwiftUI
/// animation is involved anywhere (the earlier attempts layered clip sweeps
/// and offsets over a static layout, and every seam showed); this is the
/// same drive-the-truth approach that fixed the drag reorder.
@MainActor
final class SidebarToggleAnimator: ObservableObject {
    private weak var sidebarState: SidebarState?
    private weak var layout: SidebarLayoutModel?
    private var isPeekPresenting: () -> Bool = { false }
    // `nonisolated(unsafe)` so deinit can invalidate; every other access is
    // main-actor.
    private nonisolated(unsafe) var timer: Timer?
    /// The width the pane rests at when open, captured at hide time and
    /// restored after, so the sweep never corrupts the persisted width.
    private var restingWidth: CGFloat = 0
    /// A hide sweep is running: `isVisible` stays true until it lands. Mirrored
    /// onto the state so a toggle mid-sweep sees the hide as requested.
    private var isHiding = false {
        didSet { sidebarState?.isHidePending = isHiding }
    }
    /// The width a running show sweep is heading to. A hide that interrupts
    /// it rests at this, not at the half-open live width.
    private var showTarget: CGFloat?

    deinit {
        timer?.invalidate()
    }

    func install(
        sidebarState: SidebarState,
        layout: SidebarLayoutModel,
        isPeekPresenting: @escaping () -> Bool
    ) {
        self.sidebarState = sidebarState
        self.layout = layout
        self.isPeekPresenting = isPeekPresenting
        sidebarState.animatedVisibilityOrchestrator = { [weak self] targetVisible in
            guard let self else { return false }
            return self.animateVisibility(to: targetVisible)
        }
    }

    /// Returns true when the change was consumed and will be applied by the
    /// sweep; false hands the change back to the instant default path.
    private func animateVisibility(to targetVisible: Bool) -> Bool {
        guard let sidebarState, let layout else { return false }
        // Only a docked pane trades width with the terminal; floating
        // visibility is the peek panel's business.
        guard sidebarState.presentationMode == .docked else { return false }
        // A second hide while one is sweeping (`isVisible` is still true
        // until it lands) is the same request; restarting it would capture
        // the half-collapsed width as the resting width.
        if isHiding && !targetVisible { return true }
        let reversesHide = isHiding && targetVisible
        SidebarNavigationTimings.begin(targetVisible ? "toggle.show" : "toggle.hide")
        cancelSweep()
        isHiding = false
        let interruptedShowTarget = showTarget
        showTarget = nil
        if targetVisible {
            // Docking over an already-revealed peek card swaps in place: the
            // card is where the pane belongs, so any sweep would be a ghost.
            if !reversesHide, isPeekPresenting() {
                return false
            }
            let target = restingWidth > 1
                ? restingWidth
                : max(layout.width, CGFloat(SessionPersistencePolicy.defaultSidebarWidth))
            // A show that reverses a hide mid-sweep glides back from where the
            // pane is now (it is still mounted) instead of snapping shut first.
            let start = reversesHide ? layout.width : 1
            sidebarState.setVisible(true)
            layout.width = start
            // The width snap above IS the first visual feedback for show (the
            // terminal steps aside in this very turn); the sweep that follows
            // is the pane gliding in.
            SidebarNavigationTimings.end("toggle.show")
            showTarget = target
            sweep(from: start, to: target) { [weak self] in self?.showTarget = nil }
            return true
        } else {
            restingWidth = interruptedShowTarget ?? layout.width
            isHiding = true
            sweep(from: layout.width, to: 1) { [weak self] in
                self?.isHiding = false
                guard let self,
                      let sidebarState = self.sidebarState,
                      let layout = self.layout else { return }
                sidebarState.setVisible(false)
                // The pane is unmounted now; restore the resting width so the
                // next show (and the persisted value) see the real width.
                layout.width = self.restingWidth
            }
            return true
        }
    }

    private func sweep(from: CGFloat, to: CGFloat, completion: (() -> Void)?) {
        let duration: TimeInterval = 0.17
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] tick in
            MainActor.assumeIsolated {
                guard let self, let layout = self.layout else {
                    tick.invalidate()
                    return
                }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / duration)
                // Ease in-out: the pane leaves and arrives, it does not snap.
                let eased = progress < 0.5
                    ? 2 * progress * progress
                    : 1 - pow(-2 * progress + 2, 2) / 2
                layout.width = from + (to - from) * CGFloat(eased)
                SidebarNavigationTimings.end("toggle.hide")
                if progress >= 1 {
                    tick.invalidate()
                    self.timer = nil
                    completion?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cancelSweep() {
        timer?.invalidate()
        timer = nil
    }
}
