import Foundation
import Testing
@testable import CmuxWorkspaces

/// In-memory host for ``AgentPIDLivenessSweepService``: serves a fixed
/// agent-PID snapshot and records every applied stale-clear batch.
@MainActor
private final class FakeSweepHost: AgentPIDLivenessSweepHosting {
    var snapshot: [UUID: [String: pid_t]] = [:]
    private(set) var appliedBatches: [[UUID: [String: pid_t]]] = []

    func agentPIDSnapshot() -> [UUID: [String: pid_t]] {
        snapshot
    }

    func applyStaleAgentPIDs(_ staleByWorkspace: [UUID: [String: pid_t]]) {
        appliedBatches.append(staleByWorkspace)
    }

    var applyCount: Int { appliedBatches.count }
}

/// A virtual-time clock matching the ``SessionAutosaveScheduler`` test clock:
/// `sleep(for:)` suspends until the test ``advance(by:)``s virtual time past the
/// deadline. Cancellation abandons the waiter, matching `ContinuousClock`.
private final class ManualReleaseClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    // Justification: a test-only virtual clock. All state is guarded by `lock`;
    // `@unchecked Sendable` is required because `Clock.now`/`sleep` are
    // nonisolated and the state is mutated from both the sleeping task and the
    // test driver.
    private let lock = NSLock()
    private var virtualNow: Duration = .zero
    private var waiters: [(deadline: Duration, resume: () -> Void)] = []

    var minimumResolution: Duration { .zero }

    var now: Instant {
        lock.lock(); defer { lock.unlock() }
        return Instant(offset: virtualNow)
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if deadline.offset <= virtualNow {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((deadline.offset, { continuation.resume() }))
                    lock.unlock()
                }
            }
        } onCancel: {
            // The registered waiter never resumes, matching a cancelled real
            // sleep whose continuation is abandoned.
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        virtualNow += duration
        var fired: [() -> Void] = []
        while let index = waiters.firstIndex(where: { $0.deadline <= virtualNow }) {
            fired.append(waiters.remove(at: index).resume)
        }
        lock.unlock()
        fired.forEach { $0() }
    }

    var pendingSleepCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }
}

@MainActor
@Suite struct AgentPIDLivenessSweepServiceTests {
    private func settle() async {
        for _ in 0..<12 { await Task.yield() }
    }

    // MARK: - Pure staleness probe (kill(pid, 0) / ESRCH)

    @Test func nonPositivePidIsStaleUnconditionally() {
        let workspace = UUID()
        let stale = AgentPIDLivenessSweepService.staleKeys(in: [
            workspace: ["zero": 0, "negative": -1]
        ])
        // The probed dead pid is carried verbatim so the apply can re-validate.
        #expect(stale == [workspace: ["zero": 0, "negative": -1]])
    }

    @Test func exitedProcessIsStaleAndLiveProcessSurvives() {
        let workspace = UUID()
        // PID 1 (launchd) always exists; a very high PID is overwhelmingly
        // unlikely to exist, so kill(pid, 0) returns ESRCH for it.
        let deadPid: pid_t = 2_000_000_000
        let stale = AgentPIDLivenessSweepService.staleKeys(in: [
            workspace: ["live": 1, "dead": deadPid]
        ])
        #expect(stale == [workspace: ["dead": deadPid]])
    }

    @Test func workspaceWithNoStaleKeysIsOmitted() {
        let live = UUID()
        let dead = UUID()
        let stale = AgentPIDLivenessSweepService.staleKeys(in: [
            live: ["a": 1],
            dead: ["b": 0]
        ])
        #expect(stale == [dead: ["b": 0]])
    }

    @Test func emptySnapshotProducesNoStaleKeys() {
        #expect(AgentPIDLivenessSweepService.staleKeys(in: [:]).isEmpty)
    }

    /// The stale set must carry the *exact* pid each key was probed dead at, so
    /// the apply can skip a key whose live pid no longer matches (a key
    /// reassigned to a fresh live agent during the off-main probe window). Two
    /// non-positive pids on distinct keys must come back with their own values,
    /// not collapsed to a key-only set.
    @Test func staleSetCarriesPerKeyProbedDeadPid() {
        let workspace = UUID()
        let stale = AgentPIDLivenessSweepService.staleKeys(in: [
            workspace: ["a": 0, "b": -7]
        ])
        #expect(stale[workspace]?["a"] == 0)
        #expect(stale[workspace]?["b"] == -7)
    }

    /// Models the host re-validation the apply performs: a key whose live pid was
    /// reassigned away from the probed dead pid during the off-main window must
    /// survive, while a key still holding the probed dead pid is cleared. This is
    /// the behavior `TabManager.applyStaleAgentPIDs` enforces with
    /// `agentPIDs[key] == probedDeadPid`; here it is checked against the
    /// service's stale-set contract (the carried pid) without an app `Workspace`.
    @Test func applyReValidationSkipsReassignedLiveKey() {
        let workspace = UUID()
        let deadPid: pid_t = 2_000_000_000
        let stale = AgentPIDLivenessSweepService.staleKeys(in: [
            workspace: ["claude_code": deadPid]
        ])
        // recordAgentPID reassigned the same key to a fresh live pid during the
        // probe window.
        var liveMap: [String: pid_t] = ["claude_code": 4242]
        for (key, probedDeadPid) in stale[workspace] ?? [:] {
            if liveMap[key] == probedDeadPid {
                liveMap[key] = nil
            }
        }
        // The reassigned live entry is untouched; the legacy synchronous sweep
        // could never have cleared it.
        #expect(liveMap["claude_code"] == 4242)

        // Same key still holding the probed dead pid IS cleared.
        var deadMap: [String: pid_t] = ["claude_code": deadPid]
        for (key, probedDeadPid) in stale[workspace] ?? [:] {
            if deadMap[key] == probedDeadPid {
                deadMap[key] = nil
            }
        }
        #expect(deadMap["claude_code"] == nil)
    }

    // MARK: - Cadence

    @Test func firstSweepWaitsOneFullInterval() async {
        let host = FakeSweepHost()
        host.snapshot = [UUID(): ["k": 0]] // a stale entry, so apply would fire
        let clock = ManualReleaseClock()
        let service = AgentPIDLivenessSweepService(interval: .seconds(30), clock: clock)
        service.attach(host: host)
        service.start()
        await settle()

        // The legacy DispatchSource used `deadline: .now() + 30`, so nothing
        // sweeps before the first interval elapses.
        #expect(host.applyCount == 0)

        clock.advance(by: .seconds(30))
        await settle()
        #expect(host.applyCount == 1)
        service.stop()
    }

    @Test func sweepRepeatsEveryInterval() async {
        let workspace = UUID()
        let host = FakeSweepHost()
        host.snapshot = [workspace: ["k": 0]]
        let clock = ManualReleaseClock()
        let service = AgentPIDLivenessSweepService(interval: .seconds(30), clock: clock)
        service.attach(host: host)
        service.start()
        await settle()

        clock.advance(by: .seconds(30))
        await settle()
        clock.advance(by: .seconds(30))
        await settle()
        #expect(host.applyCount == 2)
        #expect(host.appliedBatches.allSatisfy { $0 == [workspace: ["k": 0]] })
        service.stop()
    }

    @Test func sweepWithNoStaleEntriesDoesNotApply() async {
        let host = FakeSweepHost()
        host.snapshot = [UUID(): ["live": 1]] // launchd, never stale
        let clock = ManualReleaseClock()
        let service = AgentPIDLivenessSweepService(interval: .seconds(30), clock: clock)
        service.attach(host: host)
        service.start()
        await settle()

        clock.advance(by: .seconds(30))
        await settle()
        #expect(host.applyCount == 0)
        service.stop()
    }

    @Test func emptySnapshotSkipsApply() async {
        let host = FakeSweepHost() // empty snapshot
        let clock = ManualReleaseClock()
        let service = AgentPIDLivenessSweepService(interval: .seconds(30), clock: clock)
        service.attach(host: host)
        service.start()
        await settle()

        clock.advance(by: .seconds(30))
        await settle()
        #expect(host.applyCount == 0)
        service.stop()
    }

    // MARK: - Lifecycle

    @Test func stopPreventsFurtherSweeps() async {
        let host = FakeSweepHost()
        host.snapshot = [UUID(): ["k": 0]]
        let clock = ManualReleaseClock()
        let service = AgentPIDLivenessSweepService(interval: .seconds(30), clock: clock)
        service.attach(host: host)
        service.start()
        await settle()

        service.stop()
        clock.advance(by: .seconds(60))
        await settle()
        #expect(host.applyCount == 0)
    }

    @Test func startIsIdempotent() async {
        let host = FakeSweepHost()
        host.snapshot = [UUID(): ["k": 0]]
        let clock = ManualReleaseClock()
        let service = AgentPIDLivenessSweepService(interval: .seconds(30), clock: clock)
        service.attach(host: host)
        service.start()
        service.start() // second start must not arm a second loop
        await settle()

        #expect(clock.pendingSleepCount == 1)
        clock.advance(by: .seconds(30))
        await settle()
        #expect(host.applyCount == 1) // one loop, one apply per interval
        service.stop()
    }
}
