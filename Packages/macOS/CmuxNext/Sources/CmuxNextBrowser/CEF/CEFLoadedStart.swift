import Foundation

/// `CEFRuntime.start` in two parts, for a caller that picks the turn `CefInitialize` runs on
/// (ChromiumWarmup's step, an idle task that runs only after the input quiet, in a slot that may
/// overrun): ``loadEnded()`` awaits the framework load (in host mode, the one host attach) and the
/// start's disk inputs (``CEFStartInputs``, prepared off the main thread) and keeps both, and
/// ``start(trigger:)`` then runs the main-thread part on the caller's turn, with no await, so
/// `CefInitialize` lands in that turn and not in a later, unscheduled one. Chrome runs its
/// deferred browser work the same way: the task posted after startup does the work itself
/// (chrome/browser/after_startup_task_utils.cc).
final class CEFLoadedStart {
    private let runtime: CEFRuntime
    private var boot: Result<CEFRuntimeBoot, CEFRuntime.BootError>?
    private var inputs: CEFStartInputs?

    init(runtime: CEFRuntime) {
        self.runtime = runtime
    }

    /// Returns once the framework load ended, or in host mode once the host attached (at once when
    /// neither runs), and the start's inputs are prepared; keeps both for ``start(trigger:)``. Never
    /// promotes a fenced preload read: the warm start waits behind the startup fence.
    func loadEnded() async {
        guard runtime.startError() == nil, runtime.state != .ready else { return }
        if let hostStart = runtime.hostStart {
            boot = await hostStart.attached().map(CEFRuntimeBoot.host)
            runtime.publishHelperParent()  // the attached host's pid, as `CEFRuntime.start` does
        } else {
            // Behind the startup fence the preload's map is made only after its framework read.
            await runtime.libraryLoadEnded()
            guard let loadTask = runtime.loadTask else { return }
            boot = await loadTask.value.map(CEFRuntimeBoot.inProcess)
        }
        inputs = await runtime.preparedStartInputs().value
    }

    /// Runs `CefInitialize` (the main-thread part of `CEFRuntime.start`) on this turn. Idempotent.
    ///
    /// - Returns: True when Chromium runs; false when no load has ended yet, or Chromium failed or shut down.
    func start(trigger: String) -> Bool {
        if runtime.state == .ready { return true }
        guard let boot, let inputs else { return false }
        guard runtime.startError() == nil else {
            // A quit during the attach: this runtime never uses the host, so release its wire (as `start` does).
            if runtime.state == .shutDown, case .success(.host(let host)) = boot { host.remote.detach() }
            return false
        }
        do {
            try runtime.finishStart(boot, inputs: inputs, environment: ProcessInfo.processInfo.environment, trigger: trigger)
        } catch {
            return false
        }
        return true
    }
}
