import os

/// The app's one ``MainJobGate`` and its on/off switch (p04-input-076): the composition root makes
/// it while feature `mainJobGate` is on and has it follow the `debug.mainJobGate` setting. On, the
/// runtime hook is installed and the run loop drains it; off, the hook is not installed at all and
/// held jobs go first.
///
/// ```swift
/// let jobGate = MainJobGateSwitch(pending: pending)
/// jobGate.follow(on: mainWork) { settings.loadCount >= 1 ? settings.snapshot.mainJobGate.enabled : nil }
/// application.jobGateState = jobGate.state   // the dispatching flag, set around each event's route
/// ```
@MainActor
public final class MainJobGateSwitch {
    /// The word the hook reads; the application marks each event's dispatch on it.
    public var state: InputPendingState { gate.state }
    public let gate: MainJobGate
    /// Input and frame tasks the gate passes.
    public let work: MainWork
    private let pending: SessionInputPending
    private var hook: MainJobGateHook?
    private var runLoop: MainJobGateRunLoop?
    private var observation: ServiceObservation<Bool?>?
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "input")

    /// - Parameter pending: The session's pending input (the main-thread budget's source).
    public convenience init(pending: SessionInputPending) {
        self.init(pending: pending, gate: MainJobGate(state: InputPendingState()))
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// ``init(pending:)`` whose gate records each job enqueued during input into `recorder`
    /// (`debug.input hops`, task 022).
    public convenience init(pending: SessionInputPending, recorder: MainJobGateDiagnostics?) {
        self.init(pending: pending, gate: MainJobGate(state: InputPendingState(), recorder: recorder))
    }
    #endif

    init(pending: SessionInputPending, gate: MainJobGate) {
        self.pending = pending
        self.gate = gate
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
            runLoop = MainJobGateRunLoop(gate: gate, pending: pending)
        } catch {
            Self.logger.error("main job gate not installed: \(String(describing: error), privacy: .public)")
        }
    }
}
