@testable import CmuxSwiftRenderUI
import Testing

/// JavaScriptCore's concurrent JIT maps a 512 KB arena granule for each JIT
/// worklist thread and leaves it mapped when the idle thread exits, so a JS
/// sidebar that re-renders now and then grows the app by a region per update
/// burst (https://github.com/manaflow-ai/cmux/issues/47871).
struct JavaScriptCoreProcessOptionsTests {
    @Test("Turns concurrent JIT off before JavaScriptCore reads its options, then clears the variable")
    func disablesConcurrentJITBeforeInitializing() {
        var calls: [String] = []
        let applied = JavaScriptCoreProcessOptions.disableConcurrentJIT(
            environment: [:],
            setVariable: { calls.append("set \($0)=\($1)") },
            unsetVariable: { calls.append("unset \($0)") },
            initializeJavaScriptCore: { calls.append("initialize") }
        )

        #expect(applied)
        #expect(calls == [
            "set JSC_useConcurrentJIT=0",
            "initialize",
            "unset JSC_useConcurrentJIT",
        ])
    }

    @Test("Leaves a value the user set in the environment alone")
    func keepsExplicitSetting() {
        var calls: [String] = []
        let applied = JavaScriptCoreProcessOptions.disableConcurrentJIT(
            environment: ["JSC_useConcurrentJIT": "1"],
            setVariable: { calls.append("set \($0)=\($1)") },
            unsetVariable: { calls.append("unset \($0)") },
            initializeJavaScriptCore: { calls.append("initialize") }
        )

        #expect(!applied)
        #expect(calls.isEmpty)
    }
}
