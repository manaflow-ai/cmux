public import CmuxNextActions

/// A person's run refused because this Mac's service is older than the app (``RefusalStrings/daemonOutdated``)
/// restarts that service the way a server update does (``DaemonService/restartForUpdate(timeout:)``: terminals keep
/// running) and then runs once more, instead of "Quit and reopen cmux to update it" (Leo, 2026-11-17: "remove bullshit
/// ceremony + bullshit text + bullshit belt and suspenders"). Runs that come in while the restart runs wait for it
/// too, in order. Nothing shows unless the restart fails: then one line, ``RefusalStrings/daemonUpdateFailed``.
///
/// Only a service this app can restart (connected, launched by this app: `updateHandOff`), and never twice for the
/// same one: a service that came back from a restart and still lacks the capability is refused with the reason, so an
/// action never loops restarts. Another machine's reason names that machine
/// (``DaemonService/missingCapabilityMessage(_:)``). The CLI, MCP and scripts read the reason as before.
///
/// Stop condition: one restart at a time, bounded by `restartForUpdate`'s own timeout; each held run is performed
/// once after it, and a run still refused then shows its reason.
@MainActor
public final class DaemonUpdateRetry {
    /// Restarts this Mac's service; the generation of the one that answered after it, nil when none did.
    private let restart: @MainActor @Sendable () async -> String?
    /// The generation of the running service when this app can restart it, else nil.
    private let restartable: @MainActor @Sendable () -> String?
    private weak var registry: ActionRegistry?
    private var held: [@MainActor () -> Void] = []
    private var restarting: Task<Void, Never>?
    /// The service a restart brought up: it is not restarted again.
    private var restartedInto: String?
    /// True while held runs are performed again: a run still refused then shows its refusal.
    private var replaying = false

    public convenience init(daemon: DaemonService) {
        self.init(restart: { await daemon.restartForUpdate().map { "\($0.generation)" } },
                  restartable: { daemon.updateHandOff == nil ? nil : daemon.identity.map { "\($0.generation)" } })
    }

    init(restart: @escaping @MainActor @Sendable () async -> String?, restartable: @escaping @MainActor @Sendable () -> String?) {
        self.restart = restart
        self.restartable = restartable
    }

    /// Whether a person's run refused for `reason` restarts this Mac's service and runs again.
    public nonisolated static func retries(_ reason: String) -> Bool { reason == RefusalStrings.daemonOutdated }

    /// Runs waiting for the restart now.
    var waitingCount: Int { held.count }

    /// Whether a run refused for `reason` waits for a restart now: one is running, or one can start.
    private func takes(_ reason: String) -> Bool {
        guard Self.retries(reason), !replaying else { return false }
        if restarting != nil { return true }
        guard let running = restartable() else { return false }
        return running != restartedInto
    }

    /// The registry keeps this retry alive (its closures hold it; it holds the registry weakly).
    public func bind(into registry: ActionRegistry) {
        self.registry = registry
        registry.unavailableRecoveries.append { [self] _, reason in
            guard takes(reason) else { return nil }
            return ActionRecovery { [self] id, invocation in hold(id, invocation) }
        }
        registry.refusalDeferrals.append { [self] id, invocation, reason in
            guard takes(reason) else { return false }
            hold(id, invocation)
            return true
        }
    }

    /// Keeps the run for after the restart, starting it when none runs.
    func hold(_ id: ActionID, _ invocation: ActionInvocation) {
        held.append { [weak self] in
            guard let registry = self?.registry else { return }
            CloudSignInRecovery.resume(id, invocation, in: registry)
        }
        guard restarting == nil else { return }
        let restart = restart
        // task-owner: one restart of this Mac's service; ends when its successor answers or restartForUpdate's bound passes.
        restarting = Task { [weak self] in
            let successor = await restart()
            self?.finish(successor: successor)
        }
    }

    private func finish(successor: String?) {
        let runs = held
        held = []
        restarting = nil
        guard let successor else {
            registry?.refuse(RefusalStrings.daemonUpdateFailed)
            return
        }
        restartedInto = successor
        replaying = true
        defer { replaying = false }
        for run in runs { run() }
    }
}

extension DaemonService {
    /// Binds the ways a person's run waits for this Mac's service instead of being refused: while it starts
    /// (``DaemonStartupWait``) and while an outdated one restarts (``DaemonUpdateRetry``).
    public func bindRunWaits(into registry: ActionRegistry) {
        DaemonStartupWait(daemon: self).bind(into: registry)
        DaemonUpdateRetry(daemon: self).bind(into: registry)
    }
}
