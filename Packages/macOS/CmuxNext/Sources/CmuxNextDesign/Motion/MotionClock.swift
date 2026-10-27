public import AppKit
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Something whose springs a ``MotionClock`` steps: the tab strip, the
/// layout's panes and dividers, the sidebar rows.
@MainActor
public protocol MotionAnimating: AnyObject {
    /// One frame: advances every spring by `tick.elapsed` seconds (clamped) and applies the presented
    /// values (layer frames). A sampler of presented values (a `MotionPath`, a render-server spring)
    /// evaluates at `tick.targetTimestamp`, when the frame is shown, not at `CACurrentMediaTime()`.
    /// Returns true while anything still moves.
    func motionStep(_ tick: FrameTick) -> Bool
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
    // frame-client: the window's one chrome spring clock (motion.md P4), on main while an animator moves
    private lazy var client = FrameClient(owner: "Motion.clock", rate: .motion, scheduler: resolveScheduler) { [weak self] tick in
        self?.tick(tick) ?? false
    }
    /// The scheduler the clock ticks on: its window's (``FrameScheduler/app`` for the app clock).
    private let resolveScheduler: @MainActor () -> FrameScheduler
    /// The animator whose `motionStep` runs now, and whether it called `run` on itself
    /// meanwhile (new targets): it stays on the clock even when that step reports rest.
    private var steppingID: ObjectIdentifier?
    private var steppingRearmed = false
    /// Frames delivered while something moved (debug).
    public private(set) var frames: UInt64 = 0
    /// ``waitIdle()`` callers, by id, resumed where the last animator leaves the clock.
    private var idleWaiters: [UInt64: OnceContinuation<Bool, OnceContinuationError>] = [:]
    private var lastIdleWaiterID: UInt64 = 0
    /// Frames a step keeps ``MotionActivity`` running for: up to the next step, and the last step's commit.
    private static let activityFrames: Double = 2

    convenience init(window: NSWindow?) {
        self.init(scheduler: { [weak window] in window.map(FrameScheduler.forWindow) ?? .app })
    }

    /// A clock on the scheduler `resolve` returns when it starts ticking (tests: a fake-link scheduler).
    init(scheduler resolve: @escaping @MainActor () -> FrameScheduler) {
        resolveScheduler = resolve
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

    /// The clocks that can step an animator now: those `windows` already have (none is created) and the app
    /// clock window-less views share.
    public static func existing(in windows: [NSWindow]) -> [MotionClock] {
        windows.compactMap { objc_getAssociatedObject($0, &associationKey) as? MotionClock } + [app]
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
        MotionActivity.began(seconds: Self.activityFrames * FrameTick.defaultRefreshInterval)
    }

    /// Stops stepping `animator` (it left its window).
    public func stop(_ animator: some MotionAnimating) {
        let id = ObjectIdentifier(animator)
        guard let entry = entries.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        MotionTrace.end(entry.trace, id: id)
        if entries.isEmpty {
            client.deactivate()
            resumeIdleWaiters()
        }
    }

    public func isRunning(_ animator: some MotionAnimating) -> Bool {
        entries[ObjectIdentifier(animator)] != nil
    }

    /// Animators being stepped now (debug).
    public var running: [String] { order.compactMap { entries[$0]?.trace } }

    /// True while no animator steps: none is on the clock, or its scheduler dropped the client (its window
    /// closed), so the entries left behind never step again.
    public var isIdle: Bool { entries.isEmpty || !client.isActive }

    /// Returns true once no animator steps on this clock (at once when none does), or false when the task was
    /// cancelled. A continuation resumed where the last animator leaves the clock (``stop(_:)``, the frame it
    /// rests on): no frame client, observation or timer. The oracle's settle awaits it (`debug.oracle.settle`).
    public func waitIdle() async -> Bool {
        if isIdle { return true }
        lastIdleWaiterID &+= 1
        let id = lastIdleWaiterID
        return await withTaskCancellationHandler {
            // A dropped waiter reads as not idle, as a cancelled one does.
            (try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                if isIdle {
                    continuation.resume(returning: true)
                    return
                }
                idleWaiters[id] = continuation
            }) ?? false
        } onCancel: {
            // task-owner: one hop to the clock's actor to resume this cancelled wait's continuation
            // main-hop-allow: the cancel handler runs on the canceller's thread; the hop only resumes the oracle's cancelled wait, no frame work
            Task { @MainActor in self.idleWaiters.removeValue(forKey: id)?.resume(returning: false) }
        }
    }

    /// ``waitIdle()`` callers parked now (tests).
    var idleWaiterCount: Int { idleWaiters.count }

    private func resumeIdleWaiters() {
        guard entries.isEmpty, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for continuation in waiters.values { continuation.resume(returning: true) }
    }

    /// One frame. While `debug.motion` records, the main-thread work of the whole frame
    /// (`clock`) and of each animator (its trace name) is timed (`MotionTrace.measure`).
    private func tick(_ tick: FrameTick) -> Bool {
        MotionTrace.measure("clock") { step(tick) }
    }

    private func step(_ tick: FrameTick) -> Bool {
        frames &+= 1
        MotionActivity.began(seconds: Self.activityFrames * (tick.refreshInterval ?? FrameTick.defaultRefreshInterval))
        if MotionTrace.isEnabled { MotionTrace.sample("clock.dt_ms", tick.elapsed * 1000) }
        // Animators started during this frame step from the next one.
        for id in order {
            guard let entry = entries[id] else { continue }
            (steppingID, steppingRearmed) = (id, false)
            let moving = entry.animator.map { animator in MotionTrace.measure(entry.trace) { animator.motionStep(tick) } }
            steppingID = nil
            // Rest, unless the step re-armed itself (`run` during its own step): its new targets move next frame.
            guard moving == true || (moving != nil && steppingRearmed) else {
                entries[id] = nil
                MotionTrace.end(entry.trace, id: id)
                continue
            }
        }
        order.removeAll { entries[$0] == nil }
        resumeIdleWaiters()
        return !entries.isEmpty
    }
}
