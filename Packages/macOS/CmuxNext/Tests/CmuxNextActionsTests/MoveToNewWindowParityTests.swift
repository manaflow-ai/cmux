@testable import CmuxNextActions
import Foundation
import Testing

/// Lawrence 2026-10-19: "For a bunch of right-click actions and Cmd+Shift+P
/// actions, we need 'Move to New Window.'" Every movable object (a tab, a
/// tab group, a pane, a workspace, a workspace group, a screen, a screen
/// group) offers Move to New Window on its right-click menu, in the palette,
/// on the CLI (`cmux <noun> move-to-new-window`, also spelled
/// `cmux <noun> move-to-window --new`) and in MCP, and every surface runs
/// the same registered action.
@MainActor
@Suite struct MoveToNewWindowParityTests {
    /// The object menus that must offer Move to New Window.
    nonisolated static let contexts: [ActionMenuContext] = [.tabGroup, .pane, .workspaceRow, .workspaceGroup, .screen, .screenGroup]

    @Test func tabMoveToNewWindowStaysPaletteAndCLIReachable() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "tab.moveToNewWindow" })
        #expect(descriptor.surfacePlan.palette.isOffered)
        #expect(descriptor.surfacePlan.cli?.isOffered == true)
        #expect(descriptor.surfacePlan.mcp?.isOffered == true)
        #expect(!ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .tab)).contains(descriptor.id))
    }

    /// The Move to New Window action of a menu: the placed action whose CLI
    /// verb is `move-to-new-window`.
    static func moveToNewWindow(in context: ActionMenuContext) -> ActionDescriptor? {
        let placed = Set(ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context)))
        return ActionCatalog.all.first { placed.contains($0.id) && $0.cliName.hasSuffix(" move-to-new-window") }
    }

    @Test(arguments: contexts) func everyObjectMenuOffersMoveToNewWindow(_ context: ActionMenuContext) throws {
        let descriptor = try #require(Self.moveToNewWindow(in: context), "\(context) menu has no Move to New Window")
        let plan = descriptor.surfacePlan
        #expect(plan.palette.isOffered, "\(descriptor.id): not in the palette")
        #expect(plan.cli?.isOffered == true, "\(descriptor.id): no CLI verb")
        #expect(plan.mcpExemption == nil, "\(descriptor.id): not in MCP")
        // The menu's object is the action's target, so a right-click moves what it was on.
        let kind = try #require(context.targetKind)
        #expect(descriptor.targets.first == kind, "\(descriptor.id) targets \(descriptor.targets), not \(kind)")
    }

    /// One verb per noun: `cmux pane move-to-new-window` names exactly one action.
    @Test func eachNounHasOneMoveToNewWindowVerb() {
        let verbs = ActionCatalog.all.filter { $0.cliName.hasSuffix(" move-to-new-window") }.map(\.cliName)
        #expect(Set(verbs).count == verbs.count, "duplicate verbs: \(verbs.sorted())")
        for noun in ["tab", "tab-group", "pane", "workspace", "workspace-group", "screen", "screen-group"] {
            #expect(verbs.contains("\(noun) move-to-new-window"), "no `cmux \(noun) move-to-new-window`")
        }
    }
}
