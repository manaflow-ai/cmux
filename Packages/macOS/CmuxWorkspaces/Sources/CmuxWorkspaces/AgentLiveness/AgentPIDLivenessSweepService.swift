public import Foundation

/// Periodically probes the PIDs of agent status entries across a window's
/// workspaces and clears the entries whose process has exited.
///
/// This is the safety net for cases where no agent hook fires (SIGKILL, crash):
/// every 30 s it checks each tracked agent PID with `kill(pid, 0)`, and for any
/// process that no longer exists it clears the stale status entry, refreshes the
/// workspace's agent ports, and clears the leftover notifications. Faithful lift
/// of the legacy `TabManager.startAgentPIDSweepTimer()` /
/// `sweepStaleAgentPIDs()` pair.
///
/// **Isolation design.** `@MainActor`, not an actor. The legacy timer fired on a
/// utility `DispatchQueue` but immediately hopped to `DispatchQueue.main.async`
/// before reading `tabs` or mutating any workspace, so every state touch already
/// lived on the main actor. The only work that does *not* belong on main is the
/// `kill(2)` probe loop, which runs on a detached task over a `Sendable`
/// snapshot and returns a `Sendable` stale-key set; the service reads the
/// snapshot and applies the clears on the main actor through
/// ``AgentPIDLivenessSweepHosting``. Co-locating the cadence and the apply with
/// their callers (the rule from stage 3b: state lives where its callers live)
/// turns every bridge into a plain call; an actor here would only manufacture an
/// isolation domain the apply immediately re-enters. The host is held weakly:
/// the per-window `TabManager` owns this service, so a strong back-reference
/// would be a retain cycle, and the periodic task's `[weak self]` guard no-ops
/// after the owner deallocates (matching the sidebar git/PR services, which the
/// same `TabManager` deinit relies on).
///
/// **Timer as a Clock task, not `DispatchSource`.** The repeating 30 s timer
/// becomes a generation-guarded `Task` that sleeps on an injected
/// `any Clock<Duration>` (production passes `ContinuousClock`; tests pass a
/// manual clock). The generation guard makes a stale fire after ``stop()`` a
/// no-op without a `Task.isCancelled` check, the same pattern as
/// ``SessionAutosaveScheduler``. `Clock.sleep` is the injected, cancellable,
/// testable replacement for the banned `DispatchSource.makeTimerSource` +
/// `DispatchQueue.main.async` the legacy code used (CONVENTIONS §5,
/// `asyncAfter`/DispatchSource bans).
///
/// **Behavior delta.** The scheduling primitive changes (DispatchSource utility
/// queue + main hop → injected Clock task); the 30 s cadence, the `kill(pid, 0)`
/// / `ESRCH` staleness test, the `pid <= 0` short-circuit, and the per-workspace
/// clear/refresh/notification order are preserved byte-for-byte. The single
/// observable difference is that a probe tick now runs off the main actor and
/// applies on the next main-actor turn, so the apply observes the workspace's
/// state at apply time rather than at the (legacy synchronous) read time.
///
/// The legacy sweep read `agentPIDs`, probed `kill(pid, 0)`, and cleared the key
/// in one synchronous main-actor turn, so the pid it cleared was always the pid
/// it had just found dead (a zero-width race window). To keep that read/clear
/// atomicity across the new suspension point, the stale set carries the *probed
/// dead pid* per key (``staleKeys(in:)`` returns `[UUID: [String: pid_t]]`), and
/// the host clears a key only when `agentPIDs[key]` still equals that pid at
/// apply time. If `recordAgentPID` reassigned the key to a fresh live pid during
/// the off-main probe (an agent that respawned and re-emitted its hook), the
/// apply sees the mismatch and leaves the live entry untouched, exactly as the
/// synchronous legacy could never have cleared it.
@MainActor
public final class AgentPIDLivenessSweepService {
    /// The interval between liveness sweeps. Legacy `DispatchSource` repeating
    /// period (30 s).
    private let interval: Duration

    /// Clock backing the repeating-timer sleep. Injected so tests drive cadence
    /// deterministically; production uses `ContinuousClock`.
    private let clock: any Clock<Duration>

    private weak var host: (any AgentPIDLivenessSweepHosting)?

    /// The repeating-timer task, or nil when stopped. Legacy
    /// `TabManager.agentPIDSweepTimer` (a `DispatchSourceTimer`).
    private var timerTask: Task<Void, Never>?

    /// Monotonic generation; the timer task captures its generation and no-ops
    /// after a newer ``start()``/``stop()`` bumps it, so a stale fire is absorbed
    /// without a `Task.isCancelled` check.
    private var generation: UInt64 = 0

    /// Creates a sweep service.
    ///
    /// - Parameters:
    ///   - interval: the sweep period (default 30 s, the legacy
    ///     `DispatchSource` repeating period).
    ///   - clock: the clock backing the timer sleep (default `ContinuousClock`).
    public init(
        interval: Duration = .seconds(30),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.interval = interval
        self.clock = clock
    }

    /// Wires the app-side host that supplies the agent-PID snapshot and applies
    /// the stale clears. Held weakly.
    public func attach(host: any AgentPIDLivenessSweepHosting) {
        self.host = host
    }

    /// Arms the repeating sweep timer if not already armed. Lifts the legacy
    /// `startAgentPIDSweepTimer()`: the legacy timer waited one full period
    /// before its first fire (`deadline: .now() + 30, repeating: 30`), so this
    /// loop sleeps the interval *before* each sweep, preserving that initial
    /// 30 s delay.
    public func start() {
        guard timerTask == nil else { return }
        generation &+= 1
        let armedGeneration = generation
        timerTask = Task { [weak self, clock, interval] in
            while !Task.isCancelled {
                try? await clock.sleep(for: interval)
                guard let self, self.generation == armedGeneration else { return }
                await self.sweep()
            }
        }
    }

    /// Cancels the repeating timer. Lifts the legacy
    /// `agentPIDSweepTimer?.cancel()` from `TabManager.deinit`. Safe to call
    /// from the owner's `deinit` is *not* required: the `[weak self]` periodic
    /// task no-ops after the owner deallocates, so the legacy nonisolated-deinit
    /// cancel is optional; an explicit `stop()` is provided for symmetry and
    /// tests.
    public func stop() {
        generation &+= 1
        timerTask?.cancel()
        timerTask = nil
    }

    /// Runs one sweep: snapshot the agent-PID map on the main actor, probe it
    /// off-main, then apply any stale clears on the main actor. Lifts the legacy
    /// `sweepStaleAgentPIDs()` split across the actor boundary.
    private func sweep() async {
        guard let host else { return }
        let snapshot = host.agentPIDSnapshot()
        guard !snapshot.isEmpty else { return }
        let stale = await Task.detached { [snapshot] in
            Self.staleKeys(in: snapshot)
        }.value
        guard !stale.isEmpty else { return }
        // The host may have deallocated while the detached probe ran.
        host.applyStaleAgentPIDs(stale)
    }

    /// The `(workspaceId, key)` entries in `snapshot` whose process has exited,
    /// probed with `kill(pid, 0)`, each mapped to the **probed dead pid** so the
    /// apply can re-validate it. Pure over the snapshot and free of any
    /// main-actor or `Workspace` reference, so it runs on a detached task.
    ///
    /// Lifts the legacy staleness test exactly: a `pid <= 0` entry is stale
    /// unconditionally (legacy `guard pid > 0 else { keysToRemove.append(key) }`);
    /// otherwise `kill(pid, 0) == -1` with `errno == ESRCH` (process gone) marks
    /// it stale, while `EPERM` (process exists, no permission) keeps it tracked.
    ///
    /// The value is the exact pid the probe found dead. The host clears the key
    /// only when `agentPIDs[key]` still equals this pid at apply time, so a key
    /// reassigned to a fresh live pid during the off-main probe is left intact
    /// (restoring the legacy synchronous read/clear atomicity).
    nonisolated static func staleKeys(
        in snapshot: [UUID: [String: pid_t]]
    ) -> [UUID: [String: pid_t]] {
        var result: [UUID: [String: pid_t]] = [:]
        for (workspaceId, pidsByKey) in snapshot {
            var staleForWorkspace: [String: pid_t] = [:]
            for (key, pid) in pidsByKey {
                guard pid > 0 else {
                    staleForWorkspace[key] = pid
                    continue
                }
                // kill(pid, 0) probes process liveness without sending a signal.
                // ESRCH = process doesn't exist (stale). EPERM = process exists
                // but we lack permission (not stale, keep tracking).
                errno = 0
                if kill(pid, 0) == -1, POSIXErrorCode(rawValue: errno) == .ESRCH {
                    staleForWorkspace[key] = pid
                }
            }
            if !staleForWorkspace.isEmpty {
                result[workspaceId] = staleForWorkspace
            }
        }
        return result
    }
}
