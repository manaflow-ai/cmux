import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Copy Workspace ID, Copy Pane ID and Copy IDs (#27709, classic parity): offered where classic
/// offers them (the workspace row menu, the pane and tab menus, the terminal's right-click menu),
/// and each copies classic's `key=value` text with the public id the CLI resolves: `ws_…`, not
/// the workspace's durable key.
@MainActor @Suite(.serialized)
struct CopyIdentifierActionsTests {
    static let workspaceKey = "copy-ids-project"
    static let workspaceID = "ws_0123456789abcdef0123456789abcdef"
    static let paneID = "pane_00112233445566778899aabbccddeeff"
    static let tabID = "tab_ffeeddccbbaa99887766554433221100"

    /// What the actions copied: the fixture binds them to this recorder, not the general
    /// pasteboard, which a headless test host cannot reach.
    final class Copied { var text: String? }

    struct Fixture {
        let services: AppServices
        let copied: Copied
        let workspace: WorkspaceModel
        let pane: PaneModel
        let tab: TabModel
    }

    /// One registry workspace whose one pane holds one terminal, each with its resource id.
    static func fixture() -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let copied = Copied()
        TabHandlers.bindIdentifiers(into: services.registry, context: AppActionContext(services: services)) { copied.text = $0 }
        let terminal = TabSnapshot(surface: 1, tabResourceID: ResourceID(rawValue: tabID), kind: .pty, title: "zsh", url: "")
        let pane = PaneSnapshot(id: 1, resourceID: ResourceID(rawValue: paneID), tabs: [terminal])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: workspaceKey), resourceID: ResourceID(rawValue: workspaceID),
                              name: "copy ids", screens: [screen]),
        ]))
        let workspace = services.machines.local.store.workspaces[0]
        let paneModel = workspace.screens[0].panes[0]
        return Fixture(services: services, copied: copied, workspace: workspace, pane: paneModel, tab: paneModel.tabs[0])
    }

    static func runs(_ menu: NSMenu) -> [ActionID] {
        func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
        return all(menu.items).compactMap { ActionRegistry.menuRun(of: $0)?.id }
    }

    @Test func copyWorkspaceIDCopiesThePublicIDNotTheDurableKey() {
        let f = Self.fixture()
        #expect(f.workspace.id == Self.workspaceKey, "the model's id is the durable key the old handler copied")
        let target = ActionTargetRef(kind: .workspace, id: f.workspace.id)
        #expect(f.services.registry.perform("palette.copyWorkspaceID", invocation: ActionInvocation(target: target)))
        #expect(f.copied.text == "workspace_id=\(Self.workspaceID)")

        f.copied.text = nil
        #expect(f.services.registry.perform("palette.copyWorkspaceIDAndRef", invocation: ActionInvocation(target: target)))
        #expect(f.copied.text == "workspace_ref=workspace:\(Self.workspaceID)\nworkspace_id=\(Self.workspaceID)")
    }

    @Test func copyPaneIDAndCopyIDsCopyTheCLIIDs() {
        let f = Self.fixture()
        #expect(f.services.registry.perform("palette.copyPaneID", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: f.pane.id))))
        #expect(f.copied.text == "pane_id=\(Self.paneID)")

        f.copied.text = nil
        // From the tab menu, which targets the tab: its pane.
        #expect(f.services.registry.perform("palette.copyPaneID", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: f.tab.id))))
        #expect(f.copied.text == "pane_id=\(Self.paneID)")

        f.copied.text = nil
        #expect(f.services.registry.perform("palette.copyIdentifiers", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: f.tab.id))))
        #expect(f.copied.text == "workspace_id=\(Self.workspaceID)\npane_id=\(Self.paneID)\nsurface_id=\(Self.tabID)")
    }

    /// Classic's places: the workspace row menu (Copy Workspace ID, Copy Workspace Link), the pane
    /// and tab menus (Copy Pane ID), the terminal's right-click menu (Copy IDs).
    @Test func theMenusOfferThemWhereClassicDoes() {
        let f = Self.fixture()
        let registry = f.services.registry
        let row = Self.runs(registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: f.workspace.id)))
        #expect(row.contains("palette.copyWorkspaceID"))
        #expect(row.contains("palette.copyWorkspaceLink"))
        let pane = Self.runs(registry.makeContextMenu(for: .pane, target: ActionTargetRef(kind: .pane, id: f.pane.id)))
        #expect(pane.contains("palette.copyPaneID"))
        let tab = Self.runs(PaneController.tabMenu(f.tab.id, tab: f.tab, keepsTab: false, sameKind: .terminal, registry: registry))
        #expect(tab.contains("palette.copyPaneID"))
        #expect(tab.contains("palette.copyIdentifiers"))
        let terminal = Self.runs(registry.makeContextMenu(for: .terminalSelection, target: ActionTargetRef(kind: .tab, id: f.tab.id)))
        #expect(terminal.contains("palette.copyIdentifiers"))
        #expect(terminal.contains("palette.copySurfaceLink"))
    }
}
