@testable import CmuxNextActions
import Testing

/// Every spaces feature and shortcut has a Cmd-Shift-P entry, a CLI command and an MCP action, with
/// no exceptions (Lawrence, 14223 follow-up): previous / next space, jump to space N, every space
/// verb, pin, open in a new window, reorder, and the space-scoped actions of other domains
/// (plans/cmux-next/spaces-overhaul-DESIGN.md rule 7). A verb the space's owner serves (the daemon's
/// `cmux space create`, `SurfaceExemption.ownerVerb`) is a CLI and MCP surface too: the Rust CLI
/// and the daemon's MCP tools run it.
@MainActor @Suite struct SpaceSurfacesTests {
    /// Space actions outside the `space.` prefix.
    nonisolated static let crossDomain: [ActionID] = [
        "newWindow", "palette.toggleWorkspacePin", "workspace.moveToSpace", "workspace.duplicateToSpace",
        "workspaceGroup.moveToSpace", "browser.link.openInNewSpace", "browserProfile.setSpaceDefault",
        "browserProfile.clearSpaceDefault", "sidebar.section.toggleSpaceScope", "sidebar.spaces.hide", "sidebar.spaces.show",
    ]

    /// Every space action: the `space.` prefix (the old `room.` ids are aliases of these) and ``crossDomain``.
    nonisolated static var spaceActions: [ActionID] {
        ActionCatalog.all.map(\.id).filter { $0.rawValue.hasPrefix("space.") } + crossDomain
    }

    /// The features the user named, by id: each must be in the catalog.
    nonisolated static let named: [ActionID] = [
        "space.next", "space.previous", "space.selectByNumber", "space.new", "space.newWindow", "space.openInNewWindow",
        "space.moveLeft", "space.moveRight", "space.move", "space.switch", "palette.toggleWorkspacePin", "newWindow",
    ]

    @Test(arguments: named)
    func theNamedFeatureExists(_ id: ActionID) {
        #expect(ActionCatalog.all.contains { $0.id == id }, "\(id) is no catalog action")
    }

    @Test func everySpaceActionIsInThePaletteTheCLIAndMCP() throws {
        var missing: [String] = []
        for id in Self.spaceActions {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id }, "\(id) is no catalog action")
            let plan = descriptor.surfacePlan
            let owner = plan.cli == .exempt(.ownerVerb)
            if !plan.palette.isOffered || !descriptor.isPaletteVisible { missing.append("\(id): not in Cmd-Shift-P") }
            if !(owner || plan.cli?.isOffered == true) { missing.append("\(id): no CLI verb (\(String(describing: plan.cli)))") }
            if !(owner || plan.mcp?.isOffered == true) { missing.append("\(id): no MCP tool (\(String(describing: plan.mcp)))") }
        }
        #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
    }

    /// Every space action that takes a key can be bound (Settings > Keyboard, cmux.json).
    @Test func theSpaceKeysAreRebindable() throws {
        for id in ["space.next", "space.previous", "space.selectByNumber", "space.new", "space.openInNewWindow"] as [ActionID] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(descriptor.surfaces.contains(.keyboard), "\(id) cannot take a shortcut")
        }
    }

    /// The space's right-click menu opens it in a new window.
    @Test func openInNewWindowIsInTheSpaceMenu() {
        let shown = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .profile))
        #expect(shown.contains("space.openInNewWindow"))
    }
}
