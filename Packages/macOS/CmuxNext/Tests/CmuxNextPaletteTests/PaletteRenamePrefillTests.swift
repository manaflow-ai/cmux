import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// A rename run from a sidebar context menu, a menu item or a shortcut asks
/// for the new name in the palette, starting from the current name. Dogfood
/// report (00d5c8a974): renaming a workspace from the sidebar opened an
/// empty prompt.
@MainActor
@Suite(.paletteRanker) struct PaletteRenamePrefillTests {
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
        #expect(model.selectsQuery, "\(id) selects the name so typing replaces it")
        #expect(recorder.runs.isEmpty)
    }

    /// Editing the name ends the select-all: the field keeps the caret
    /// where the user put it.
    @Test func editingTheNameDropsTheSelection() throws {
        let (controller, data, _) = makeController("renameWorkspace")
        let (target, _) = try menuTarget(.workspace, in: data)
        controller.registry.perform("renameWorkspace", invocation: ActionInvocation(target: target))
        controller.model.query = "api"
        #expect(!controller.model.selectsQuery)
    }

    /// The palette's own Rename Workspace… and Rename Tab… rows start from
    /// the focused workspace's and tab's names, selected, the same way.
    @Test func thePalettesOwnRenameRowsStartFromTheCurrentName() async {
        for (query, title) in [("rename workspace", "cmux"), ("rename tab", "zsh")] {
            let (controller, _, _) = makeController("renameWorkspace")
            let model = controller.model
            model.reset(to: controller.commandsPage())
            model.query = query
            await model.settle()
            model.handle(.submit)
            #expect(model.isTextInput, "\(query)")
            #expect(model.query == title, "\(query)")
            #expect(model.selectsQuery, "\(query)")
        }
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

    /// The prefill is a snapshot: Return on the untouched name renames
    /// nothing, so a rename made meanwhile (another window, the CLI) is not
    /// reverted, and a fallback title is never saved as a real name.
    @Test(arguments: renames)
    func returnOnTheUntouchedNameRenamesNothing(_ id: ActionID, _ kind: ActionTargetKind) throws {
        let (controller, data, recorder) = makeController(id)
        let (target, _) = try menuTarget(kind, in: data)
        var dismissed = 0
        controller.model.onDismiss = { dismissed += 1 }
        controller.registry.perform(id, invocation: ActionInvocation(target: target))
        controller.model.handle(.submit)
        #expect(recorder.runs.isEmpty, "\(id) ran on the untouched name")
        #expect(dismissed == 1, "\(id) closes")
    }

    /// The palette's own Rename Workspace… and Rename Tab… rows skip an
    /// untouched name the same way.
    @Test func thePalettesOwnRenameRowsSkipAnUntouchedName() async {
        for query in ["rename workspace", "rename tab"] {
            let (controller, data, _) = makeController("renameWorkspace")
            let model = controller.model
            model.reset(to: controller.commandsPage())
            model.query = query
            await model.settle()
            model.handle(.submit)
            #expect(model.isTextInput, "\(query)")
            model.handle(.submit)
            #expect(!data.events.contains { $0.hasPrefix("renameWorkspace:") || $0.hasPrefix("renameTab:") }, "\(query)")
        }
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
