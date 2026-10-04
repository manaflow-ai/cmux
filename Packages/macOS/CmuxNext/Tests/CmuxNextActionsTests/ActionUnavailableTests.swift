import CmuxNextActions
import Testing

/// Typed "cannot run" reasons: capability gates disable an action with a
/// reason; handlers refuse one invocation and a capturing caller sees why.
@Suite struct ActionUnavailableTests {
    @Test func unavailableReasonDisablesAndClearsWithCapability() {
        let registry = ActionRegistry.standard()
        var supported = false
        var ran = 0
        registry.bind("tabGroup.save", unavailable: { supported ? nil : "needs daemon capability tab-groups-v1" }, invoke: { _ in ran += 1 })

        #expect(registry.unavailableReason(for: "tabGroup.save") == "needs daemon capability tab-groups-v1")
        #expect(!registry.canPerform("tabGroup.save"))
        #expect(!registry.perform("tabGroup.save"))
        #expect(ran == 0)

        supported = true
        #expect(registry.unavailableReason(for: "tabGroup.save") == nil)
        #expect(registry.perform("tabGroup.save"))
        #expect(ran == 1)
    }

    @Test func bindUnavailableCountsAsBound() {
        let registry = ActionRegistry.standard()
        #expect(registry.bindUnavailable("canvasTidy", reason: "needs canvas layout"))
        #expect(registry.isBound("canvasTidy"))
        #expect(registry.unavailableReason(for: "canvasTidy") == "needs canvas layout")
    }

    @Test func refusalIsCapturedOnlyInsideCapture() {
        let registry = ActionRegistry.standard()
        var observed: [String] = []
        registry.refusalObserver = { reason, _ in observed.append(reason) }
        registry.bind("closeTab", invoke: { _ in registry.refuse("no tab to close") })

        let captured = registry.capturingRefusal { registry.perform("closeTab") }
        #expect(captured == "no tab to close")
        #expect(registry.capturingRefusal { registry.perform("quit") } == nil)

        registry.perform("closeTab")
        #expect(observed == ["no tab to close", "no tab to close"])
    }

    @Test func unboundIDsFilterByCategory() {
        let registry = ActionRegistry.standard()
        let terminal = Set(registry.unboundActionIDs(in: [.terminal]))
        #expect(terminal.contains("terminalCopy"))
        #expect(!terminal.contains("closeTab"))
        registry.bind("terminalCopy") {}
        #expect(!registry.unboundActionIDs(in: [.terminal]).contains("terminalCopy"))
    }
}
