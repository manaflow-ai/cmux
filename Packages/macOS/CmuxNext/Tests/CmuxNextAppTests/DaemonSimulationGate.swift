import Testing

/// Runs the classic-upgrade and first-launch suites one at a time with respect to each other.
///
/// Each of these suites drives a whole app against its own same-tree daemon, and the simulations make up to
/// 512 workspaces with live terminals. The apps do not share state (each owns its sidebar document, #31661).
/// But when several run at once in one test process, they share one main thread and the host's CPU, and their
/// daemons answer late: `list-workspaces`, `pin-workspace` and `rename-surface` miss the client's 2 s request deadline,
/// and each workspace whose step timed out is closed and reported lost (job 8a0204a5b3dd: 57 timeouts, 24 lost
/// huge workspaces, one for each timed-out step). With the suites serialized, the same `--filter Classic` x5
/// run had none (job 0faea94aab4e). A single huge simulation can also miss the deadline on a busy host (job 0b952f2b382d,
/// serial, base), so the gate makes the deadline less likely to be missed but does not fix it. The real fix is
/// a deadline that survives load, or a faster daemon; it is tracked in
/// wt/handoff/followups.md ("#31661: the 2 s request deadline under load").
///
/// The gate holds a suite's whole run (the huge simulation's phases share one launch), and suites without it
/// still run in parallel around it.
nonisolated struct DaemonSimulationGate: SuiteTrait, TestScoping {
    static let owner = SuiteMutex()

    var isRecursive: Bool { false }

    /// The suite itself only: its tests run inside the suite's hold.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite && testCase == nil ? self : nil
    }

    @concurrent func provideScope(for test: Test, testCase: Test.Case?,
                                  performing function: @concurrent @Sendable () async throws -> Void) async throws {
        await Self.owner.acquire()
        do {
            try await function()
        } catch {
            await Self.owner.release()
            throw error
        }
        await Self.owner.release()
    }
}

extension Trait where Self == DaemonSimulationGate {
    /// The suite's whole-daemon simulations run while no other gated suite runs (``DaemonSimulationGate``).
    static var oneDaemonSimulationAtATime: Self { DaemonSimulationGate() }
}

/// One holder at a time, FIFO, no busy waiting.
actor SuiteMutex {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the hold to the longest waiter, or frees it.
    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
