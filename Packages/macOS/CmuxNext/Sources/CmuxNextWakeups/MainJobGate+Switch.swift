import Foundation
import os

/// The app's one ``MainJobGate`` and its on/off switch: the composition root makes
/// it while feature `mainJobGate` is on and has it follow the `debug.mainJobGate` setting. On, the
/// runtime hook is installed and the run loop drains it; off, the hook is not installed at all and
/// held jobs go first.
///
/// ```swift
/// let jobGate = MainJobGateSwitch(pending: pending, holding: mainWork)
/// jobGate.follow(on: mainWork) { settings.loadCount >= 1 ? settings.snapshot.mainJobGate.enabled : nil }
/// // Around each event's route (CmuxApplication):
/// let outer = jobGate.beginDispatch()
/// defer { jobGate.endDispatch(restoring: outer) }
/// ```
@MainActor
public final class MainJobGateSwitch {
    /// The word the hook reads.
    public var state: InputPendingState { gate.state }
    /// The gate it turns on and off.
    public let gate: MainJobGate
    /// Input and frame tasks the gate passes.
    public let work: MainWork
    private let pending: SessionInputPending
    /// The main thread's deadline queue: the run loop's deadline wake.
    private let wakeUps: MainWakeUpQueue
    private var hook: MainJobGateHook?
    private var runLoop: MainJobGateRunLoop?
    private var observation: ServiceObservation<Bool?>?
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "input")

    /// - Parameters:
    ///   - pending: The session's pending input (the main-thread budget's source).
    ///   - wakeUps: The main thread's deadline queue (`MainWorkScheduler.wakeUps`).
    public convenience init(pending: SessionInputPending, wakeUps: MainWakeUpQueue) {
        self.init(pending: pending, gate: MainJobGate(state: InputPendingState()), wakeUps: wakeUps)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// ``init(pending:wakeUps:)`` whose gate records each job enqueued during input into `recorder`
    /// (`debug.input hops`, task 022).
    public convenience init(pending: SessionInputPending, wakeUps: MainWakeUpQueue, recorder: MainJobGateDiagnostics?) {
        self.init(pending: pending, gate: MainJobGate(state: InputPendingState(), recorder: recorder), wakeUps: wakeUps)
    }
    #endif

    init(pending: SessionInputPending, gate: MainJobGate, wakeUps: MainWakeUpQueue) {
        self.pending = pending
        self.gate = gate
        self.wakeUps = wakeUps
        work = MainWork(gate: gate)
    }

    /// Whether the hook is installed.
    public var isEnabled: Bool { hook?.isInstalled == true }

    /// Follows `enabled` (nil until the settings load: nothing changes).
    public func follow(on mainWork: MainWorkScheduler, enabled: @escaping @MainActor () -> Bool?) {
        guard observation == nil else { return }
        observation = ServiceObservation(.background, owner: "MainJobGate.setting", on: mainWork, read: enabled) { [weak self] on in
            if let on { self?.setEnabled(on) }
        }
    }

    /// Installs the hook and starts the run loop's side, or stops both and releases what is held.
    public func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        guard on else {
            hook?.uninstall()
            runLoop?.invalidate()
            runLoop = nil
            return
        }
        do {
            let hook = try self.hook ?? MainJobGateHook()
            try hook.install(gate)
            self.hook = hook
            runLoop = MainJobGateRunLoop(gate: gate, pending: pending, wakeUps: wakeUps)
        } catch {
            Self.logger.error("main job gate not installed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Dispatch (CmuxApplication.route)

    /// Marks an event in dispatch: the main-actor jobs its route enqueues pass the gate. Returns
    /// whether one already was (a nested `sendEvent`).
    public func beginDispatch() -> Bool {
        state.beginDispatch()
    }

    /// Ends the dispatch ``beginDispatch()`` began. At the outer dispatch's end the pending kinds
    /// are published again: the event just dispatched no longer holds the jobs made after it in
    /// the same pass; input still on its way does.
    public func endDispatch(restoring outer: Bool) {
        state.endDispatch(restoring: outer)
        guard !outer, !state.bits.isDisjoint(with: .kinds) else { return }
        state.publish(pending.pendingKinds(uptime: ProcessInfo.processInfo.systemUptime))
    }
}
