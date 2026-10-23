import AppKit
@testable import CmuxNextActions
import Testing

/// u5402 (Oct 20): "Make sure we can send messages in the iMessage UI via right clicking." The
    /// right-click on a workspace and an agent chat offers Send Message… (the Chief's chat, about
    /// it); the compact tab menu leaves this infrequent action to the palette. Selected text in a
    /// terminal or a page offers Send to Chief and Send To…; the
/// palette and `cmux chat send` (and so MCP) offer Send Message To…. Each row runs its catalog
/// action through the registry, with the right-clicked object as its target.
@MainActor
struct HomeSendMessageMenuTests {
    typealias Run = (id: ActionID, target: ActionTargetRef?, arguments: [String: ActionValue])

    private func allActions(_ menu: NSMenu) -> [Run] {
        menu.items.flatMap { item in
            (ActionRegistry.menuRun(of: item).map { [$0] } ?? []) + (item.submenu.map(allActions) ?? [])
        }
    }

    private func menu(_ context: ActionMenuContext, _ target: ActionTargetRef?, arguments: [String: ActionValue] = [:]) -> NSMenu {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["home.messageAbout", "home.sendSelectionToChief", "home.sendSelectionTo"] { registry.bind(id, invoke: { _ in }) }
        registry.context = ActionContext(rawValue: .max)
        return registry.makeContextMenu(for: context, target: target, entries: ContextMenuCatalog.shared.entries(for: context),
                                        implied: [], arguments: arguments)
    }

    @Test(arguments: [(ActionMenuContext.workspaceRow, ActionTargetKind.workspace, "ws_1"),
                      (.agentChat, .tab, "tab_agent")])
    func anObjectsMenuOffersSendMessage(context: ActionMenuContext, kind: ActionTargetKind, id: String) throws {
        let target = ActionTargetRef(kind: kind, id: id)
        let run = try #require(allActions(menu(context, target)).first { $0.id == "home.messageAbout" }, "\(context) has no Send Message…")
        #expect(run.target == target)
    }

    @Test func theTrimmedTabMenuLeavesSendMessageToThePalette() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "home.messageAbout" })
        #expect(descriptor.surfacePlan.palette.isOffered)
        let ids = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .tab))
        #expect(!ids.contains(descriptor.id))
    }

    /// The workspace menu keeps it at the top level, not under More (it is a frequent row).
    @Test func theWorkspaceMenuShowsSendMessageOnTop() {
        let top = menu(.workspaceRow, ActionTargetRef(kind: .workspace, id: "ws_1")).items.compactMap { ActionRegistry.menuRun(of: $0)?.id }
        #expect(top.contains("home.messageAbout"))
    }

    @Test(arguments: [ActionMenuContext.terminalSelection, .browserSelection])
    func selectedTextOffersSendToChiefAndSendTo(context: ActionMenuContext) {
        let arguments: [String: ActionValue] = context == .browserSelection ? ["text": .string("hello")] : [:]
        let runs = allActions(menu(context, ActionTargetRef(kind: .tab, id: "tab_1"), arguments: arguments))
        let ids = runs.map(\.id)
        #expect(ids.contains("home.sendSelectionToChief"))
        #expect(ids.contains("home.sendSelectionTo"))
        if context == .browserSelection {
            #expect(runs.first { $0.id == "home.sendSelectionToChief" }?.arguments["text"] == .string("hello"))
        }
    }

    /// Cmd+Shift+P lists Send Message To…; the CLI verb is `cmux chat send` (MCP follows the CLI).
    @Test func thePaletteAndTheCLIOfferSendMessageTo() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "home.messageTo" })
        #expect(descriptor.surfacePlan.palette.isOffered)
        #expect(descriptor.surfacePlan.cli?.isOffered == true)
        #expect(descriptor.surfacePlan.mcp?.isOffered == true)
        #expect(descriptor.cliName == "chat send")
        #expect(descriptor.arguments.map(\.name) == ["to", "text"])
        #expect(descriptor.arguments.first { $0.name == "to" }?.suggestions?.source == ActionSuggestions.homeRecipients)
    }
}
