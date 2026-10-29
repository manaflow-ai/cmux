public import Testing

/// Gives one test at a time RenderStats' hooks.
///
/// The hooks swap `NSView` and `CALayer` IMPs process-wide, and Swift Testing runs suites in parallel. An
/// instance armed while another one's hooks are in captures them as its originals, and the first one's
/// disarm then restores IMPs under the second: RenderStatsTests saw a second arm make new hooks
/// (`disarmedHooksAreTheOriginalIMPs`) while MotionGateMainWorkTests counted with an instance of its own.
/// Every suite that arms a RenderStats carries `.renderHooks` (RenderStatsTests, MotionGateMainWorkTests,
/// PaneCloseMotionTests, TabDragGhostRenderServerTests, SidebarInvalidationTests, PaletteInvalidationTests); each of
/// its tests holds the hooks for its whole run, arm to release. It lives in CmuxNextTestSupport because a package
/// `swift test` runs every test target in one process, so the hooks are shared across targets too.
public nonisolated struct RenderHooksExclusive: SuiteTrait, TestTrait, TestScoping {
    static let slot = RenderHooksSlot()

    public init() {}

    public var isRecursive: Bool { true }

    /// One scope per test function; never for the suite itself, which would hold the hooks while its tests wait.
    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite || testCase != nil ? nil : self
    }

    @concurrent public func provideScope(for test: Test, testCase: Test.Case?,
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

extension Trait where Self == RenderHooksExclusive {
    /// Runs each test of the suite while no other test in the process holds RenderStats' hooks.
    public static var renderHooks: Self { RenderHooksExclusive() }
}

/// One holder at a time, FIFO, no busy waiting.
actor RenderHooksSlot {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the hooks to the longest waiter, or frees them.
    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
