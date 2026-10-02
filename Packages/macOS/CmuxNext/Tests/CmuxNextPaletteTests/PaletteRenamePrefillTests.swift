import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// A rename run from a sidebar context menu, a menu item or a shortcut asks
/// for the new name in the palette, starting from the current name. Dogfood
/// report (00d5c8a974): renaming a workspace from the sidebar opened an
/// empty prompt.
@MainActor
@Suite struct PaletteRenamePrefillTests {
    /// Every rename that asks through the palette, with the kind it renames.
    nonisolated static let renames: [(ActionID, ActionTargetKind)] = [
        ("renameWorkspace", .workspace), ("renameTab", .tab), ("workspaceGroup.rename", .workspaceGroup),
        ("tabGroup.rename", .tabGroup), ("cloudRenameMachine", .machine), ("sidebar.section.rename", .sidebarSection),
    ]

    final class Recorder {
        var runs: [ActionInvocation] = []
    }

    /// A registry whose argument collector is the palette's: what
    /// `PaletteController.collectArguments` does, without putting a panel on
    /// screen.
    func makeController(_ id: ActionID) -> (PaletteController, MockPaletteData, Recorder) {
        let registry = ActionRegistry.standard()
        let data = MockPaletteData()
        let recorder = Recorder()
        registry.context.formUnion(registry.descriptor(for: id)?.requires ?? [])
        registry.bind(id, invoke: { recorder.runs.append($0) })
        let controller = PaletteController(registry: registry, sources: data.sources, frecencyPersistence: nil)
        registry.argumentCollector = { [weak controller] id, invocation in
            guard let controller, let descriptor = registry.descriptor(for: id) else { return }
            let flow = PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: data)
            controller.model.reset(to: flow.effect(collected: invocation), fallback: controller.commandsPage())
        }
        return (controller, data, recorder)
    }

    /// The object a context menu targets: the last listed, never the
    /// focused one.
    func menuTarget(_ kind: ActionTargetKind, in data: MockPaletteData) throws -> (ActionTargetRef, String) {
        let option = try #require(data.targets(of: kind).last)
        return (ActionTargetRef(kind: kind, id: option.id), option.title)
    }

    @Test(arguments: renames)
    func renameStartsFromTheCurrentName(_ id: ActionID, _ kind: ActionTargetKind) throws {
        let (controller, data, recorder) = makeController(id)
        let (target, title) = try menuTarget(kind, in: data)
        #expect(controller.registry.perform(id, invocation: ActionInvocation(target: target)))
        let model = controller.model
        #expect(model.isTextInput, "\(id) asks for the name")
        #expect(model.query == title, "\(id) starts from the current name")
        #expect(recorder.runs.isEmpty)
    }

    @Test(arguments: renames)
    func returnCommitsTheEditedName(_ id: ActionID, _ kind: ActionTargetKind) throws {
        let (controller, data, recorder) = makeController(id)
        let (target, _) = try menuTarget(kind, in: data)
        controller.registry.perform(id, invocation: ActionInvocation(target: target))
        let model = controller.model
        model.query = "api"
        model.handle(.submit)
        let argument = try #require(controller.registry.descriptor(for: id)?.arguments.first { $0.isRequired })
        #expect(recorder.runs.count == 1)
        #expect(recorder.runs.first?[argument.name] == .string("api"))
        #expect(recorder.runs.first?.target == target)
    }

    @Test func returnOnTheUntouchedNameKeepsIt() throws {
        let (controller, data, recorder) = makeController("renameWorkspace")
        let (target, title) = try menuTarget(.workspace, in: data)
        controller.registry.perform("renameWorkspace", invocation: ActionInvocation(target: target))
        controller.model.handle(.submit)
        #expect(recorder.runs.first?["name"] == .string(title))
    }

    /// One Escape closes the prompt: it never just clears the name.
    @Test func escapeCancels() throws {
        let (controller, data, recorder) = makeController("renameWorkspace")
        let (target, _) = try menuTarget(.workspace, in: data)
        var dismissed = 0
        controller.model.onDismiss = { dismissed += 1 }
        controller.registry.perform("renameWorkspace", invocation: ActionInvocation(target: target))
        controller.model.handle(.escape)
        #expect(dismissed == 1)
        #expect(recorder.runs.isEmpty)
    }
}
