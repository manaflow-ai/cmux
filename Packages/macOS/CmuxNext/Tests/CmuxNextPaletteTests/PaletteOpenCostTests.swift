import CmuxNextActions
import CmuxNextPalette
import Testing

/// Opening the palette builds one row per catalog action. That runs on the
/// main thread on every open, so it must not do per-action work the open
/// does not need: target lists (every workspace, tab, pane) are read only
/// when the user runs an action that asks for one.
@Suite(.paletteRanker) struct PaletteOpenCostTests {
    final class CountingTargets: PaletteTargetSource {
        var calls = 0
        func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
            calls += 1
            return [PaletteTargetOption(id: "w1", title: "first workspace")]
        }
    }

    @Test func openingReadsNoTargetLists() async {
        let targets = CountingTargets()
        var runs: [ActionInvocation] = []
        let registry = ActionRegistry.standard()
        registry.bind("tabGroup.moveToWorkspace", invoke: { runs.append($0) })
        let provider = RegistryPaletteProvider(registry: registry, includeUnbound: true)
        provider.targets = targets
        let items = provider.makeItems()
        #expect(items.count > 100)
        #expect(targets.calls == 0, "building the rows read \(targets.calls) target lists")

        // Running an action that takes a target still lists them.
        let model = PaletteModel(persistence: nil)
        model.reset(to: PalettePageSpec(id: "commands", title: "Commands", placeholder: "", symbol: "command", providers: [provider]))
        model.query = "move tab group to workspace"
        await model.settle()
        #expect(model.selectedRowID == "action:tabGroup.moveToWorkspace")
        model.handle(.submit)
        #expect(targets.calls == 1)
        #expect(model.rows.map(\.item.title) == ["first workspace"])
        model.handle(.submit)
        #expect(runs.first?["workspace"] == .target(ActionTargetRef(kind: .workspace, id: "w1")))
    }
}
