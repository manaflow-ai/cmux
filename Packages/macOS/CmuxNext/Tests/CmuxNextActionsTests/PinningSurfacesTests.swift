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

    /// A workspace row's menu offers pinning once, at its top (plans/cmux-next/ui-simplify.md, Pin: "one Pin row in the
    /// menu"): More repeats no pin row of any kind, by id or by title.
    @Test func aWorkspaceRowsMenuPinsOnceAtItsTop() throws {
        let catalog = ContextMenuCatalog.shared
        let entries = catalog.entries(for: .workspaceRow)
        let titles = Dictionary(ActionCatalog.all.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let labels = catalog.labels(for: .workspaceRow)
        let isPin = { (id: ActionID) in
            let title = labels[id] ?? titles[id] ?? ""
            return id.rawValue.range(of: "pin", options: .caseInsensitive) != nil || title.range(of: "pin", options: .caseInsensitive) != nil
        }
        let pins = catalog.referencedIDs(entries).filter(isPin)
        #expect(pins == ["palette.toggleWorkspacePin"], "pin rows in the workspace menu: \(pins)")
        let more = entries.flatMap { entry -> [ContextMenuEntry] in
            if case .folder(.more, let rows) = entry { return rows } else { return [] }
        }
        let morePins = catalog.referencedIDs(more).filter(isPin)
        #expect(morePins.isEmpty, "More repeats a pin row: \(morePins)")
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
}
