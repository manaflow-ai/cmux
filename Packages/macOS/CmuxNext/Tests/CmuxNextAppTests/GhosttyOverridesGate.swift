import Testing

/// Runs one test at a time among the suites that drive a `TerminalThemeSetting` (#36891).
///
/// `TerminalThemeSetting.follow` puts cmux.json's appearance on the Ghostty runtime's process-wide overrides
/// (`GhosttyRuntime.themeOverride`, `themeEdits`, `fontOverride`, `backgroundOverride`) and repaints the app's theme
/// store, and these suites assert those values across their `await`s. Swift Testing runs suites in parallel in one
/// process (`.serialized` orders only a suite's own tests), so two of them interleave at their awaits: one's `follow`
/// or teardown replaces the other's overrides mid-test. Every suite that drives one carries `.ghosttyOverrides`, and
/// each of its tests holds the one slot for its whole run.
nonisolated struct GhosttyOverridesGate: SuiteTrait, TestTrait, TestScoping {
    static let slot = GhosttyOverridesSlot()

    var isRecursive: Bool { true }

    /// One scope per test function; never for the suite itself, which would hold the slot while its tests wait for it.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite || testCase != nil ? nil : self
    }

    @concurrent func provideScope(for test: Test, testCase: Test.Case?,
                                  performing function: @concurrent @Sendable () async throws -> Void) async throws {
        await Self.slot.acquire()
        do {
            try await function()
        } catch {
            await Self.slot.release()
            throw error
        }
        await Self.slot.release()
    }
}

extension Trait where Self == GhosttyOverridesGate {
    /// Runs each test of the suite alone among the suites that drive the Ghostty overrides (``GhosttyOverridesGate``).
    static var ghosttyOverrides: Self { GhosttyOverridesGate() }
}

/// The gate's one slot: FIFO, no busy waiting.
actor GhosttyOverridesSlot {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the slot to the longest waiter, or frees it.
    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
