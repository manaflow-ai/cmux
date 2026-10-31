import AppKit
@testable import CmuxNextActions
import Foundation
import Testing

/// The Space pickers from a right-click (unimpl-audit-actions rows 2-6): the menu's own Space is
/// the answer of New Workspace in Space… and New Window in Space… (they used to open the palette on
/// "which Space?"), and the workspace and group menus list the spaces as a submenu (Move Workspace
/// to Space ▸ Work), never a row that opens the palette. Swap with Session… still asks for the
/// other pane: a right-clicked pane is the one that moves, not its partner.
@MainActor @Suite struct SpacePickerMenuTests {
    /// A registry whose every catalog action records its run and whose collector records each
    /// palette request; the menus list the spaces Work and Home.
    final class Recorder {
        let registry = ActionRegistry.standard()
        var runs: [(ActionID, ActionInvocation)] = []
        var asked: [ActionID] = []

        init() {
            registry.context = ActionContext(rawValue: .max)
            for descriptor in ActionCatalog.all {
                let id = descriptor.id
                registry.bind(id, invoke: { [unowned self] in runs.append((id, $0)) })
            }
            registry.argumentCollector = { [unowned self] id, _ in asked.append(id) }
            registry.targetChoices = { _, kind, _ in
                kind == .profile ? ActionTargetChoices(cases: [ActionEnumCase(value: "work", title: "Work"), ActionEnumCase(value: "home", title: "Home")]) : nil
            }
        }
    }

    @Test(arguments: ["space.newWorkspace", "space.newWindow"] as [ActionID])
    func aRightClickedSpaceIsTheSpaceTheActionUses(_ id: ActionID) {
        let recorder = Recorder()
        let space = ActionTargetRef(kind: .profile, id: "work")
        #expect(recorder.registry.perform(id, invocation: ActionInvocation(target: space, origin: .user)))
        #expect(recorder.asked.isEmpty, "\(id) asked the palette for a space although the menu's space was right-clicked")
        #expect(recorder.runs.first?.0 == id)
        #expect(recorder.runs.first?.1.target == space)
    }

    @Test func swapWithSessionStillAsksForTheOtherPane() {
        let recorder = Recorder()
        let pane = ActionTargetRef(kind: .pane, id: "p1")
        #expect(recorder.registry.perform("palette.swapWithSession", invocation: ActionInvocation(target: pane, origin: .user)))
        #expect(recorder.asked == ["palette.swapWithSession"])
        #expect(recorder.runs.isEmpty)
    }

    /// The submenu of `id`'s row in `context`'s right-click menu on `target`: each space's title.
    static func choices(_ recorder: Recorder, _ context: ActionMenuContext, _ target: ActionTargetRef, _ id: ActionID) -> [NSMenuItem]? {
        func find(_ menu: NSMenu) -> [NSMenuItem]? {
            for item in menu.items {
                guard let submenu = item.submenu else { continue }
                let rows = submenu.items.filter { ($0.representedObject as? ActionMenuPayload)?.id == id }
                if !rows.isEmpty, rows.count == submenu.items.count { return rows }
                if let found = find(submenu) { return found }
            }
            return nil
        }
        return find(recorder.registry.makeContextMenu(for: context, target: target))
    }

    @Test(arguments: [
        (ActionMenuContext.workspaceRow, ActionTargetKind.workspace, "workspace.moveToSpace" as ActionID),
        (.workspaceRow, .workspace, "workspace.duplicateToSpace"),
        (.workspaceGroup, .workspaceGroup, "workspaceGroup.moveToSpace"),
    ])
    func theMenuListsTheSpacesAsASubmenu(_ context: ActionMenuContext, _ kind: ActionTargetKind, _ id: ActionID) throws {
        let recorder = Recorder()
        let target = ActionTargetRef(kind: kind, id: "t1")
        let rows = try #require(Self.choices(recorder, context, target, id), "\(id) is not a submenu of spaces in the \(context) menu")
        #expect(rows.map(\.title) == ["Work", "Home"])

        // Choosing Home runs the action on the right-clicked object with that space; no palette.
        let home = try #require(rows.last)
        _ = (home.target as? NSObject)?.perform(home.action, with: home)
        #expect(recorder.asked.isEmpty)
        #expect(recorder.runs.first?.0 == id)
        #expect(recorder.runs.first?.1.target == target)
        #expect(recorder.runs.first?.1["space"] == .target(ActionTargetRef(kind: .profile, id: "home")))
    }
}
