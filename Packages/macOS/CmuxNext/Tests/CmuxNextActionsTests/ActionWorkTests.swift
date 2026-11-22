import CmuxNextActions
import Testing

/// Handlers report the daemon work they start; only a capturing caller
/// (the control socket, CLI compat) collects it.
@Suite struct ActionWorkTests {
    @Test func capturingCollectsTrackedWorkAndOtherRunsDoNot() async {
        let registry = ActionRegistry.standard()
        registry.bind("splitRight", invoke: { _ in registry.track(Task { "split: failed" }) })

        #expect(registry.perform("splitRight"))  // keyboard-style run: nothing captured
        let work = registry.capturingWork { _ = registry.perform("splitRight") }
        #expect(work.count == 1)
        #expect(await work.first?.value == "split: failed")
        #expect(registry.capturingWork {}.isEmpty)
    }
}
