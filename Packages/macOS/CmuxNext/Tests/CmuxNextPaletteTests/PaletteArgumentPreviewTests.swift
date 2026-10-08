import CmuxNextActions
import CmuxNextPalette
import Testing

/// Enumeration argument pages preview the highlighted option live
/// (theme pickers) and revert when left without choosing.
@MainActor @Suite(.paletteRanker) struct PaletteArgumentPreviewTests {
    final class Recorder {
        var values: [String?] = []
        var runs: [ActionInvocation] = []
    }

    func makeController(_ recorder: Recorder) -> PaletteController {
        let registry = ActionRegistry.standard()
        registry.bind("tabGroup.setColor", invoke: { recorder.runs.append($0) })
        var sources = MockPaletteData().sources
        sources.argumentPreview = { id, argument, value, _ in
            #expect(id == "tabGroup.setColor")
            #expect(argument == "color")
            recorder.values.append(value)
        }
        let controller = PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
        controller.model.reset(to: controller.commandsPage())
        return controller
    }

    func openColorPage(_ model: PaletteModel) async {
        model.query = "set tab group color"
        await model.settle()
        model.handle(.submit)
        await model.settle()
    }

    @Test func movingTheSelectionPreviewsAndPoppingReverts() async {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let model = controller.model
        await openColorPage(model)
        // The row selected as the page opens is not previewed.
        #expect(recorder.values.isEmpty)
        model.handle(.moveDown)
        #expect(recorder.values == ["blue"])
        model.hover("option:red")
        #expect(recorder.values.last == "red")
        model.hover(nil)
        #expect(recorder.values.last == "blue")
        model.handle(.back)
        #expect(model.depth == 1)
        #expect(recorder.values.last == .some(nil))
    }

    @Test func choosingCommitsWithoutReverting() async {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let model = controller.model
        await openColorPage(model)
        model.handle(.moveDown)
        model.handle(.submit)
        #expect(recorder.runs.first?["color"] == .string("blue"))
        model.didHide()
        model.reset(to: controller.commandsPage())
        #expect(recorder.values == ["blue"])
    }

    @Test func closingWithoutChoosingReverts() async {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let model = controller.model
        await openColorPage(model)
        model.didHide()
        #expect(recorder.values == [nil])
        // Starting over does not revert twice.
        model.reset(to: controller.commandsPage())
        #expect(recorder.values == [nil])
    }
}
