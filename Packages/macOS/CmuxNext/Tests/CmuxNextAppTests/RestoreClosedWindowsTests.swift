import CmuxNextLayout
import Testing

/// The memory of the launch window the person closed during the restore (`RestoreClosedWindows`):
/// it outlasts the restore only while a workspace the restore asked for can still arrive.
@MainActor struct RestoreClosedWindowsTests {
    private static func ended(awaiting ids: Set<String>, barrier: UInt64 = 10, applied: UInt64 = 5,
                              listed: Set<String> = [], in registry: WindowRegistry = WindowRegistry()) -> RestoreClosedWindows {
        var memory = RestoreClosedWindows()
        memory.closed("launch", launch: true)
        memory.closed("saved-front")
        memory.awaiting(ids, barrier: barrier)
        memory.restoreEnded(in: registry, applied: applied) { listed.contains($0) }
        return memory
    }

    @Test func onlyTheClosedLaunchWindowOutlastsTheRestoreWhileItsWorkspaceIsUnreported() {
        let memory = Self.ended(awaiting: ["first"])
        #expect(memory.launchWindowID == "launch")
        #expect(memory.windows == ["launch"])
        #expect(memory.awaited == ["first"])
    }

    @Test func theLateWorkspaceGoesToTheClosedLaunchWindowAndTheMemoryEnds() {
        var memory = Self.ended(awaiting: ["first"])
        // Reconcile's fallback window is the launch window, kept closed in the same step.
        var registry = WindowRegistry()
        registry.reconcile(live: ["first"], dead: [], fallbackWindow: memory.launchWindowID ?? "new")
        memory.keepClosed(&registry)
        #expect(registry.owner(of: "first") == "launch")
        #expect(registry.window("launch")?.isOpen == false)
        memory.settle(in: registry, applied: 11) { $0 == "first" }
        #expect(memory == RestoreClosedWindows())
    }

    @Test func aWorkspaceTheStoreAppliedPastWithoutListingIsGoneAndEndsTheMemory() {
        var memory = Self.ended(awaiting: ["first"])
        memory.settle(in: WindowRegistry(), applied: 9) { _ in false }
        #expect(memory.launchWindowID == "launch", "the store has not applied past the create yet")
        memory.settle(in: WindowRegistry(), applied: 10) { _ in false }
        #expect(memory == RestoreClosedWindows(), "a workspace that never came kept the closed launch window as the fallback")
    }

    @Test func nothingAwaitedOrTheLaunchWindowReopenedForgetsAtTheEnd() {
        #expect(Self.ended(awaiting: []) == RestoreClosedWindows())
        var memory = RestoreClosedWindows()
        memory.closed("launch", launch: true)
        memory.awaiting(["first"], barrier: 10)
        memory.reopened("launch")
        memory.restoreEnded(in: WindowRegistry(), applied: 0) { _ in false }
        #expect(memory == RestoreClosedWindows())
    }
}
