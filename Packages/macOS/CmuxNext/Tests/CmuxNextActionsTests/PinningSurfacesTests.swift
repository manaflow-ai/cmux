@testable import CmuxNextActions
import Testing

/// Pinning everywhere (plans/cmux-next/pinning-DESIGN.md, Lawrence 2026-10-20: "everything about
/// pinning that can be pinned ... works, and is accessible from right click/cmd shift p/mcp etc").
/// Each pinnable object has one Pin/Unpin action; its right-click menu, the palette, the CLI and
/// MCP run that same action, and a person can give it a shortcut in Settings and cmux.json.
/// Pin/Unpin Group (`workspaceGroup.togglePin`) is in the palette on a219's branch
/// (pinned-groups-a219); `SidebarOrderingSurfacesTests` covers its menu row.
@MainActor @Suite struct PinningSurfacesTests {
    /// The pin actions, one per pinnable object (a tab group pins by saving it, Chrome's model).
    nonisolated static let pinActions: [ActionID] = [
        "palette.toggleWorkspacePin", "palette.toggleTabPin", "screen.togglePin", "tabGroup.save", "tabGroup.unsave",
        "browser.extension.pin", "browser.extension.unpin", "home.togglePin",
    ]

    @Test(arguments: pinActions)
    func pinIsInThePaletteTheCLIAndMCP(_ id: ActionID) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id }, "\(id) is no catalog action")
        let plan = descriptor.surfacePlan
        #expect(plan.palette.isOffered, "\(id): not in Cmd-Shift-P")
        #expect(plan.cli?.isOffered == true, "\(id): no CLI verb")
        #expect(plan.mcp?.isOffered == true, "\(id): no MCP tool")
    }

    /// The toggles a person pins with often can take a key (Settings > Keyboard, cmux.json);
    /// only Pin/Unpin Tab has a default (Opt-Cmd-P).
    @Test(arguments: ["palette.toggleWorkspacePin", "palette.toggleTabPin", "home.togglePin"] as [ActionID])
    func pinToggleTakesAShortcut(_ id: ActionID) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
        #expect(descriptor.surfaces.contains(.keyboard), "\(id) cannot take a shortcut")
    }

    @Test(arguments: [("palette.toggleWorkspacePin", ActionMenuContext.workspaceRow), ("palette.toggleTabPin", .tab),
                      ("screen.togglePin", .screen)] as [(ActionID, ActionMenuContext)])
    func pinIsInItsObjectsMenu(_ id: ActionID, _ context: ActionMenuContext) {
        let shown = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context))
        #expect(shown.contains(id), "\(id) is not in the \(context) menu")
    }

    /// Pinning a Home conversation names the conversation and may set the state outright, so a
    /// script pins without first reading whether it is pinned.
    @Test func homePinTakesAConversationAndAState() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "home.togglePin" })
        #expect(descriptor.cliName == "home pin-unpin")
        let names = descriptor.arguments.map(\.name)
        #expect(names.contains("conversation") && names.contains("pinned"))
        #expect(descriptor.arguments.allSatisfy { !$0.isRequired })
    }

    /// cmux#25586: Chief and agents pin a workspace outright (`cmux workspace <ws> pin|unpin`, MCP
    /// `app_workspace_pin_unpin {pinned}`), so a retried pin never unpins; the palette and the
    /// right-click menu still toggle, since a person is not asked for the state.
    @Test func workspacePinTakesAWorkspaceAndAState() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "palette.toggleWorkspacePin" })
        #expect(descriptor.cliName == "workspace pin-unpin")
        #expect(descriptor.targets == [.workspace])
        let pinned = try #require(descriptor.arguments.first { $0.name == "pinned" }, "no pinned argument")
        #expect(pinned.kind == .bool)
        #expect(!pinned.isRequired)
    }
}
