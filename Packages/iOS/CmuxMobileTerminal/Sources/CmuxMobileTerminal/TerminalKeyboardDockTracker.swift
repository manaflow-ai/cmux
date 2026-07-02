#if canImport(UIKit)
import CmuxMobileTerminalKit
import UIKit

/// Ground-truth keyboard tracking for the terminal's bottom dock (replaces the
/// old duration/curve replay).
///
/// An invisible anchor view is pinned to the host's
/// `keyboardLayoutGuide.topAnchor`, so UIKit moves it inside the actual
/// keyboard animation transaction — the same private spring the keyboard
/// itself runs, including interactive dismiss, which posts no notifications
/// while the finger drags. Every display-link frame while a transition is
/// live, the host calls ``tick(targetOccupancy:)``, which samples the anchor's
/// presentation layer; the host then frame-sets the whole bottom dock
/// (toolbar + composer band) and the render layer from that one sample, so the
/// terminal edge cannot diverge from the keyboard by construction. The old
/// path animated the dock with `UIView.animate` using the notification's
/// duration + curve — a REPLAY that drifted from UIKit's keyboard spring
/// mid-flight and missed interactive dismissal entirely.
///
/// When the keyboard is down the guide rests on the bottom safe-area edge,
/// which is the identical quantity
/// `TerminalLetterboxGeometry.keyboardOccupancy` reserves — so one sampled
/// value drives both steady states and every frame of the transition between
/// them.
@MainActor
final class TerminalKeyboardDockTracker {
    /// What the host should do after a tracking tick.
    enum TickOutcome {
        /// Nothing changed (steady state, no sample, or an unchanged sample).
        case idle
        /// The sample moved: re-seat the dock and render layer from it.
        case apply
        /// The sample converged on the target (or the window expired): snap to
        /// exact target math and run any settle work.
        case settle
    }

    private struct Window {
        /// Hard stop for the tracking window. Normally tracking ends when the
        /// sampled occupancy converges on the target; the deadline covers a
        /// guide that never converges (e.g. a floating-keyboard frame the
        /// notification math resolved differently), snapping to target math.
        let deadline: CFTimeInterval
    }

    private unowned let host: UIView
    private let anchor = UIView()
    private var window: Window?
    /// The occupancy sampled on the last applied tracking tick, so every
    /// layout consumer within a frame sees the same live edge.
    private(set) var lastSampledBottomOccupancy: CGFloat?
    /// Debug/preview seams drive the keyboard height synthetically; live guide
    /// samples would immediately fight them, so they suspend tracking.
    var suspended = false
    #if DEBUG
    /// Test seam: overrides the keyboard-guide top-edge sample so tests can
    /// script an exact per-frame keyboard trajectory without a real keyboard.
    var debugGuideTopSampler: (() -> CGFloat?)?
    /// Cumulative count of `.apply` ticks since creation. UI tests read this
    /// through the dock probe to prove per-frame tracking actually engaged
    /// during a real keyboard animation (an accessibility poll is too slow to
    /// reliably land inside the ~0.4s animation window).
    private(set) var debugApplyTickCount = 0
    #endif

    init(host: UIView) {
        self.host = host
    }

    /// Whether a live tracking window (notification-driven transition or a
    /// self-armed interactive dismissal) is active.
    var isTracking: Bool { window != nil }

    /// The live occupancy the viewport snapshot should use, or nil at steady
    /// state (target math applies).
    var liveBottomOccupancy: CGFloat? { window != nil ? lastSampledBottomOccupancy : nil }

    /// Pin the invisible anchor to the host's `keyboardLayoutGuide.topAnchor`.
    /// The anchor renders nothing (clear, non-interactive) and the rest of the
    /// host stays manually frame-laid-out.
    func install() {
        anchor.isUserInteractionEnabled = false
        anchor.backgroundColor = .clear
        anchor.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(anchor)
        NSLayoutConstraint.activate([
            anchor.topAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor),
            anchor.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            anchor.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            anchor.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    /// The keyboard guide anchor's live top edge in the host's bounds, from
    /// its presentation layer while UIKit animates it (nil when it can't be
    /// trusted: off-window, pre-layout, or a debug override says so).
    func sampledGuideTop() -> CGFloat? {
        #if DEBUG
        if let sampler = debugGuideTopSampler {
            return sampler()
        }
        #endif
        guard host.window != nil, host.bounds.height > 1 else { return nil }
        let anchorLayer = anchor.layer
        let frame = (anchorLayer.presentation() ?? anchorLayer).frame
        // Zero/near-zero minY means the guide has not produced a real layout
        // yet (the guide top can never legitimately reach the view top: it
        // bottoms out at the keyboard's tallest, well below y=0).
        guard frame.minY > 0.5 else { return nil }
        return frame.minY
    }

    private func sampledBottomOccupancy() -> CGFloat? {
        guard let top = sampledGuideTop() else { return nil }
        return TerminalLetterboxGeometry.sampledBottomOccupancy(
            keyboardGuideTopY: top,
            boundsHeight: host.bounds.height
        )
    }

    /// Open a tracking window for a notification-driven keyboard transition.
    /// Seeding the live sample with the keyboard's current (pre-animation)
    /// guide position keeps the dock exactly where it is this frame; ticks
    /// then walk it along UIKit's real keyboard animation. Declines (leaving
    /// the host on the instant-apply path, exactly like the old zero-duration
    /// case) when suspended, off-window, or no trustworthy sample exists yet.
    func begin(expectedDuration: TimeInterval) {
        guard !suspended, host.window != nil, let seed = sampledBottomOccupancy() else {
            cancel()
            return
        }
        window = Window(deadline: CACurrentMediaTime() + max(expectedDuration, 0.25) + 0.75)
        lastSampledBottomOccupancy = seed
    }

    /// Drop any live tracking window without settle work (detach, suspend,
    /// synthetic-height seams).
    func cancel() {
        window = nil
        lastSampledBottomOccupancy = nil
    }

    /// One tracking step per display-link frame. Also SELF-ARMS when the guide
    /// moves with no notification-driven window active — that is interactive
    /// keyboard dismissal, which only reports a frame change when the drag
    /// ends.
    func tick(targetOccupancy: CGFloat) -> TickOutcome {
        guard !suspended, let liveOccupancy = sampledBottomOccupancy() else { return .idle }
        let converged = abs(liveOccupancy - targetOccupancy) <= 0.25
        if window == nil {
            guard !converged else { return .idle }
            // Guide moved without a notification window (interactive dismiss).
            window = Window(deadline: CACurrentMediaTime() + 2.0)
        }
        let now = CACurrentMediaTime()
        if converged || now > window!.deadline {
            cancel()
            return .settle
        }
        guard lastSampledBottomOccupancy.map({ abs($0 - liveOccupancy) > 0.05 }) ?? true else {
            return .idle
        }
        lastSampledBottomOccupancy = liveOccupancy
        // A moving sample means UIKit is still driving the guide (a long
        // interactive drag outlives any fixed deadline), so keep the window
        // open. A STALLED unconverged sample stops extending and expires,
        // snapping the dock to target math.
        if window!.deadline < now + 1.0 {
            window = Window(deadline: now + 1.0)
        }
        #if DEBUG
        debugApplyTickCount += 1
        #endif
        return .apply
    }
}
#endif
