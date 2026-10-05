import CmuxNextActions
import Testing

@Suite struct ActionRegistryTests {
    @Test func performRunsHandlerOnceAndReplacesByID() {
        let registry = ActionRegistry()
        var hits: [String] = []
        registry.register(Action(id: "a", title: "First") { hits.append("first") })
        registry.register(Action(id: "a", title: "Second") { hits.append("second") })

        #expect(registry.actions.count == 1)
        #expect(registry.perform("a"))
        #expect(hits == ["second"])
        #expect(!registry.perform("missing"))
    }

    /// A catalog action bound twice is two owners for one id: the registry reports it (and asserts
    /// in DEBUG), so a second binding can never silently replace the first.
    @Test func aSecondBindOfOneCatalogIDIsReported() {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        #expect(registry.bind("openDiffViewer") {})
        #expect(registry.duplicateBindings.isEmpty)
        registry.bind("openDiffViewer") {}
        #expect(registry.duplicateBindings == ["openDiffViewer"])
        // An unbind first is a deliberate rebind, not a duplicate.
        registry.unbind("openDiffViewer")
        registry.bind("openDiffViewer") {}
        #expect(registry.duplicateBindings == ["openDiffViewer"])
    }

    /// The policy (keybindings lead review): a real bind that replaces an unavailable placeholder
    /// (`bindUnavailable`) is the owner arriving, not a duplicate; a placeholder over a real
    /// binding is a duplicate.
    @Test func aRealBindReplacesAnUnavailablePlaceholderWithoutADuplicate() {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        registry.bindUnavailable("openDiffViewer", reason: "not yet")
        registry.bind("openDiffViewer") {}
        #expect(registry.duplicateBindings.isEmpty)
        #expect(registry.unavailableReason(for: "openDiffViewer") == nil)
        registry.bindUnavailable("openDiffViewer", reason: "not yet")
        #expect(registry.duplicateBindings == ["openDiffViewer"])
    }

    @Test func disabledActionDoesNotRun() {
        let registry = ActionRegistry()
        var ran = false
        registry.register(Action(id: "a", title: "A", isEnabled: { false }) { ran = true })
        #expect(!registry.perform("a"))
        #expect(!ran)
    }

    @Test func searchRanksPrefixAboveScatteredMatch() {
        let registry = ActionRegistry()
        registry.register(Action(id: "tab.new", title: "New Tab") {})
        registry.register(Action(id: "view.sidebar", title: "Toggle Sidebar", keywords: ["panel"]) {})
        registry.register(Action(id: "palette", title: "Command Palette") {})

        #expect(registry.search("side").map(\.id) == ["view.sidebar"])
        #expect(registry.search("panel").first?.id == "view.sidebar")
        #expect(registry.search("").count == 3)
        #expect(registry.search("zzz").isEmpty)
    }
}
