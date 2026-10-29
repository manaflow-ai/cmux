@testable import CmuxNextActions
import CmuxNextTrace
import CmuxNextWakeups
import Testing

/// The action timing names the running action and its entrypoint in the crash-key page
/// (Chrome's `ScopedCrashKeyString`): set for the run's synchronous work, the outer run's back after it.
@MainActor
struct ActionRunPageCrashKeysTests {
    @Test func aNestedRunPutsTheOuterRunsKeysBack() {
        let page = CrashKeyPage(identity: .init(role: .app))
        let timing = SignpostActionRunTiming(monitor: nil, crashKeyPage: page)
        var inner: (UInt64, UInt64) = (0, 0), afterInner: (UInt64, UInt64) = (0, 0)
        timing.time(ActionRunKey(id: "test.outer", index: 0), .mcp, input: { ActionRunInput(ageMilliseconds: -1, entrypoint: .mcp) }) {
            timing.time(ActionRunKey(id: "test.inner", index: 0), .cli, input: { ActionRunInput(ageMilliseconds: -1, entrypoint: .cli) }) {
                inner = (page.value(.actionIndex), page.value(.actionEntrypoint))
            }
            afterInner = (page.value(.actionIndex), page.value(.actionEntrypoint))
        }
        #expect(inner.0 == CrashKeySlots.stableKey("test.inner"))
        #expect(inner.1 == UInt64(ActionEntrypoint.cli.tracePosition) + 1)
        #expect(afterInner.0 == CrashKeySlots.stableKey("test.outer"))
        #expect(afterInner.1 == UInt64(ActionEntrypoint.mcp.tracePosition) + 1)
        #expect(page.value(.actionIndex) == 0)
        #expect(page.value(.actionEntrypoint) == 0)
    }

    @Test func thePageAndTheSlotsBothNameTheRun() {
        let page = CrashKeyPage(identity: .init(role: .app))
        let keys = CrashKeySlots()
        let registry = ActionRegistry(catalog: [], runTiming: SignpostActionRunTiming(monitor: nil, crashKeys: keys, crashKeyPage: page))
        var during: (UInt64, UInt64) = (0, 0)
        registry.register(Action(id: "test.page_key", title: "Page key") { during = (page.value(.actionIndex), keys.value(.actionID)) })
        #expect(registry.perform("test.page_key", invocation: ActionInvocation(origin: .mcp)))
        #expect(during.0 == CrashKeySlots.stableKey("test.page_key"))
        #expect(during.1 == CrashKeySlots.stableKey("test.page_key"))
        #expect(page.value(.actionIndex) == 0)
    }
}
