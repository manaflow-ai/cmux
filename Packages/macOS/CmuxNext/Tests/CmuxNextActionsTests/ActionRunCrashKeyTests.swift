@testable import CmuxNextActions
import CmuxNextWakeups
import Testing

/// The action timing names the running action in the crash keys (Chrome's
/// `ScopedCrashKeyString`): set for the run's synchronous work, the outer value back after it.
@MainActor
struct ActionRunCrashKeyTests {
    @Test func aRegistryRunNamesItsActionWhileItRuns() {
        let keys = CrashKeySlots()
        let registry = ActionRegistry(catalog: [], runTiming: SignpostActionRunTiming(monitor: nil, crashKeys: keys))
        var during: UInt64 = 0
        registry.register(Action(id: "test.crash_key", title: "Crash key") { during = keys.value(.actionID) })
        #expect(registry.perform("test.crash_key", invocation: ActionInvocation(origin: .mcp)))
        #expect(during == CrashKeySlots.stableKey("test.crash_key"), "the run did not name its action")
        #expect(keys.value(.actionID) == 0, "the action id stayed after the run")
    }

    @Test func aNestedRunPutsTheOuterRunsIDBack() {
        let keys = CrashKeySlots()
        let timing = SignpostActionRunTiming(monitor: nil, crashKeys: keys)
        let input = { ActionRunInput(ageMilliseconds: -1, entrypoint: .mcp) }
        var inner: UInt64 = 0, afterInner: UInt64 = 0
        timing.time(ActionRunKey(id: "test.outer", index: 0), .mcp, input: input) {
            timing.time(ActionRunKey(id: "test.inner", index: 0), .mcp, input: input) { inner = keys.value(.actionID) }
            afterInner = keys.value(.actionID)
        }
        #expect(inner == CrashKeySlots.stableKey("test.inner"))
        #expect(afterInner == CrashKeySlots.stableKey("test.outer"))
        #expect(keys.value(.actionID) == 0)
    }
}
