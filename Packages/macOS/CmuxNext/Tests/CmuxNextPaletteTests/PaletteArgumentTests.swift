import CmuxNextActions
import CmuxNextPalette
import Testing

/// The palette collects arguments inline from each action's schema.
@Suite(.paletteRanker) struct PaletteArgumentTests {
    /// Binds first, then opens the root page (items snapshot bindings on open).
    func makeController(bind: (ActionRegistry) -> Void) -> PaletteController {
        let registry = ActionRegistry.standard()
        bind(registry)
        let controller = PaletteController(registry: registry, sources: MockPaletteData().sources, frecencyPersistence: nil)
        controller.model.reset(to: controller.commandsPage())
        return controller
    }

    @Test func enumerationArgumentBecomesAList() async throws {
        var runs: [ActionInvocation] = []
        let controller = makeController { registry in
            registry.bind("tabGroup.setColor", invoke: { runs.append($0) })
        }
        let model = controller.model
        model.query = "set tab group color"
        await model.settle()
        #expect(model.selectedRowID == "action:tabGroup.setColor")
        model.handle(.submit)
        #expect(model.depth == 2)
        #expect(model.rows.count == 9)
        model.query = "cyan"
        await model.settle()
        model.handle(.submit)
        #expect(runs.first?["color"] == .string("cyan"))
    }

    @Test func targetArgumentListsTargets() async {
        var runs: [ActionInvocation] = []
        let controller = makeController { registry in
            registry.bind("tabGroup.moveToWorkspace", invoke: { runs.append($0) })
        }
        let model = controller.model
        model.query = "move tab group to workspace"
        await model.settle()
        model.handle(.submit)
        #expect(model.rows.map(\.item.title).contains("ghostty fork"))
        model.query = "ghostty"
        await model.settle()
        model.handle(.submit)
        #expect(runs.first?["workspace"] == .target(ActionTargetRef(kind: .workspace, id: "w4")))
    }

    @Test func stringArgumentBecomesTextEntry() async {
        var runs: [ActionInvocation] = []
        let controller = makeController { registry in
            registry.bind("palette.addWorkspaceChecklistItem", invoke: { runs.append($0) })
        }
        let model = controller.model
        model.query = "add checklist item"
        await model.settle()
        model.handle(.submit)
        #expect(model.isTextInput)
        model.handle(.submit)
        #expect(runs.isEmpty)
        model.query = "ship it"
        model.handle(.submit)
        #expect(runs.first?["text"] == .string("ship it"))
    }

    @Test func intArgumentValidatesRange() async {
        var runs: [ActionInvocation] = []
        let controller = makeController { registry in
            registry.bind("selectWorkspaceByNumber", invoke: { runs.append($0) })
        }
        let model = controller.model
        model.query = "select workspace 1"
        await model.settle()
        model.handle(.submit)
        #expect(model.isTextInput)
        model.query = "12"
        #expect(model.rows.first?.item.isEnabled == false)
        model.query = "4"
        model.handle(.submit)
        #expect(runs.first?["index"] == .int(4))
    }

    @Test func actionsWithoutArgumentsRunDirectly() async {
        var ran = false
        let controller = makeController { registry in
            registry.bind("tabGroup.ungroup") { ran = true }
        }
        let model = controller.model
        model.query = "ungroup tabs"
        await model.settle()
        model.handle(.submit)
        #expect(ran)
    }
}
