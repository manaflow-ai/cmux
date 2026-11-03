public import AppKit
import CmuxNextWakeups

/// Something whose springs a ``MotionClock`` steps: the tab strip, the
/// layout's panes and dividers, the sidebar rows.
@MainActor
public protocol MotionAnimating: AnyObject {
    /// Advances every spring by `dt` seconds and applies the presented
    /// values (layer frames). Returns true while anything still moves.
    func motionStep(_ dt: Double) -> Bool
    /// Ends the motion at its final state in one go (the window went out of sight: no frames).
    func motionSettle()
}

extension MotionAnimating {
    /// The fallback settle: steps at the longest frame (1/30 s) until rest, at most 20 s of motion.
    /// An animator that can jump to its end (springs: `snap()`) implements its own.
    public func motionSettle() {
        for _ in 0..<600 where motionStep(1.0 / 30.0) {}
    }
}

/// The one chrome animation clock of a window (motion.md, DESIGN P4): every
/// spring of the window steps on the same frame with the same `dt`, so a
/// tab growing in and its neighbours sliding, or a pane growing and the
/// divider beside it, can never drift apart. It is one client of the
/// window's ``FrameScheduler`` and goes idle when the last animator settles,
/// so a window at rest has no display link at all (0% idle CPU).
@MainActor
public final class MotionClock {
    private struct Entry {
        weak var animator: (any MotionAnimating)?
        var trace: String
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var order: [ObjectIdentifier] = []
    private lazy var client = FrameClient(owner: "Motion.clock", scheduler: { [weak self] in
        self?.window.map(FrameScheduler.forWindow) ?? .app
    }, settle: { [weak self] in self?.settleAll() }) { [weak self] tick in
        self?.tick(tick.elapsed) ?? false
    }
    /// The window whose scheduler the clock ticks on (nil: the app clock).
    private weak var window: NSWindow?
    /// The animator whose `motionStep` runs now, and whether it called `run` on itself
    /// meanwhile (new targets): it stays on the clock even when that step reports rest.
    private var steppingID: ObjectIdentifier?
    private var steppingRearmed = false
    /// Frames delivered while something moved (debug).
    public private(set) var frames: UInt64 = 0

    init(window: NSWindow?) {
        self.window = window
    }

    private static var associationKey: UInt8 = 0
    private static let app = MotionClock(window: nil)

    /// `window`'s clock, created on first use and kept by the window.
    public static func forWindow(_ window: NSWindow) -> MotionClock {
        if let clock = objc_getAssociatedObject(window, &associationKey) as? MotionClock { return clock }
        let clock = MotionClock(window: window)
        objc_setAssociatedObject(window, &associationKey, clock, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return clock
    }

    /// The clock of `view`'s window; window-less views share the app clock.
    public static func forView(_ view: NSView) -> MotionClock {
        view.window.map(forWindow) ?? app
    }

    /// Steps `animator` every frame until it reports rest. `trace` names its
    /// `debug.motion` span (first frame to rest). No effect while running.
    public func run(_ animator: some MotionAnimating, trace: String) {
        let id = ObjectIdentifier(animator)
        // A scheduler that dropped the client (its window closed) left stale entries behind.
        if !client.isActive, !entries.isEmpty {
            entries.removeAll()
            order.removeAll()
        }
        guard entries[id] == nil else {
            if id == steppingID { steppingRearmed = true }
            return
        }
        entries[id] = Entry(animator: animator, trace: trace)
        if !order.contains(id) { order.append(id) }
        MotionTrace.begin(trace, id: id)
        client.activate()
    }

    /// Stops stepping `animator` (it left its window).
    public func stop(_ animator: some MotionAnimating) {
        let id = ObjectIdentifier(animator)
        guard let entry = entries.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        MotionTrace.end(entry.trace, id: id)
        if entries.isEmpty { client.deactivate() }
    }

    public func isRunning(_ animator: some MotionAnimating) -> Bool {
        entries[ObjectIdentifier(animator)] != nil
    }

    /// Animators being stepped now (debug).
    public var running: [String] { order.compactMap { entries[$0]?.trace } }

    /// Ends every animator at its final state now (its window went out of sight; FrameScheduler+Sight).
    private func settleAll() {
        let settling = order.compactMap { id in entries[id].map { (id, $0) } }
        entries.removeAll()
        order.removeAll()
        for (id, entry) in settling {
            entry.animator?.motionSettle()
            MotionTrace.end(entry.trace, id: id)
        }
    }

    /// One frame. While `debug.motion` records, the main-thread work of the whole frame
    /// (`clock`) and of each animator (its trace name) is timed (`MotionTrace.measure`).
    private func tick(_ dt: Double) -> Bool {
        MotionTrace.measure("clock") { step(dt) }
    }

    private func step(_ dt: Double) -> Bool {
        frames &+= 1
        if MotionTrace.isEnabled { MotionTrace.sample("clock.dt_ms", dt * 1000) }
        // Animators started during this frame step from the next one.
        for id in order {
            guard let entry = entries[id] else { continue }
            (steppingID, steppingRearmed) = (id, false)
            let moving = entry.animator.map { animator in MotionTrace.measure(entry.trace) { animator.motionStep(dt) } }
            steppingID = nil
            // Rest, unless the step re-armed itself (`run` during its own step): its new targets move next frame.
            guard moving == true || (moving != nil && steppingRearmed) else {
                entries[id] = nil
                MotionTrace.end(entry.trace, id: id)
                continue
            }
        }
        order.removeAll { entries[$0] == nil }
        return !entries.isEmpty
    }
}
