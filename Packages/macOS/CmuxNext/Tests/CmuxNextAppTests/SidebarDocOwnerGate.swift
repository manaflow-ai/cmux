import Testing

/// Runs the live-daemon suites that drive one whole `AppServices` one at a time with respect to each other.
///
/// `AppActions.bind` reads `services.sidebarLayout`, whose first read runs `SidebarDocWiring.start` and sets
/// the process-wide `SidebarDocStore.current` to that services' store. Swift Testing runs top-level suites in
/// parallel, so two of these suites at once (each `.serialized` only inside itself) drive two daemons against
/// the one store: the later `bind` takes it, and the earlier simulation places its workspaces from the other's
/// sidebar document. Saving and restoring the store around a test does not help while both are mid-run.
///
/// The gate holds a suite's whole run, every test in it (the huge simulation's phases share one launch), and
/// suites without it still run in parallel around it. Put `.ownsSidebarDocStore` on a top-level suite that
/// binds `AppActions` and awaits its daemon across a test.
nonisolated struct SidebarDocOwnerGate: SuiteTrait, TestScoping {
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

extension Trait where Self == SidebarDocOwnerGate {
    /// The suite's run holds the one `SidebarDocStore.current` (``SidebarDocOwnerGate``).
    static var ownsSidebarDocStore: Self { SidebarDocOwnerGate() }
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
