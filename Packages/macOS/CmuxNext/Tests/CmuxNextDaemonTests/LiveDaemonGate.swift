import Testing

/// Caps how many tests in this process run a live cmux-tui daemon at once.
///
/// Swift Testing runs every suite in parallel. Starting a daemon per test
/// all at once (each spawning terminal hosts and login shells) overloads the
/// machine until ordinary replies miss their production deadlines. Every
/// live-daemon suite carries `.liveDaemon`; each of its tests takes one slot
/// for its whole run, daemon start and teardown included, so load stays
/// bounded without changing a deadline.
struct LiveDaemonGate: SuiteTrait, TestTrait, TestScoping {
    /// Concurrent live-daemon tests. Each uses a handful of PTYs, so this
    /// also bounds the run's PTY footprint.
    static let limit = 3
    static let slots = AsyncSlots(limit: limit)

    var isRecursive: Bool { true }

    /// One scope per test function; never for the suite itself, which would
    /// hold a slot while its tests wait for one.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite || testCase != nil ? nil : self
    }

    @concurrent func provideScope(for test: Test, testCase: Test.Case?,
                                  performing function: @concurrent @Sendable () async throws -> Void) async throws {
        await Self.slots.acquire()
        do {
            try await function()
        } catch {
            await Self.slots.release()
            throw error
        }
        await Self.slots.release()
    }
}

extension Trait where Self == LiveDaemonGate {
    /// Runs each test of the suite under the process-wide live-daemon cap.
    static var liveDaemon: Self { LiveDaemonGate() }
}

/// A counting semaphore for async code: FIFO, no busy waiting.
actor AsyncSlots {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        precondition(limit > 0)
        free = limit
    }

    func acquire() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the slot to the longest waiter, or frees it.
    func release() {
        if waiters.isEmpty {
            free += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
