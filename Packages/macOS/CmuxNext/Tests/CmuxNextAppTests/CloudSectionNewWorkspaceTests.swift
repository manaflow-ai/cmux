import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import Testing

/// cmux#46021: a double-click in the sidebar's empty space below a Cloud workspace's row (its machine's section) made a
/// terminal workspace on that Cloud machine: the section names the machine, and a Cloud machine's daemon hosts no New
/// Tab page, so its new workspace got a terminal. A new workspace from a Cloud machine's section is now a workspace on
/// this Mac whose chat composer has Cloud picked (New Cloud Chat's seed); its first send starts the chat in Cloud.
@MainActor @Suite(.serialized)
struct CloudSectionNewWorkspaceTests {
    @Test func aCloudMachinesSectionAsksForACloudChatComposer() {
        let rules = SidebarBridgeRules()
        #expect(rules.newWorkspace(machine: true, group: false, localWindow: true, windowDaemon: true, cloudMachine: true) == .cloudChat)
        #expect(rules.newWorkspace(machine: true, group: true, localWindow: true, windowDaemon: true, cloudMachine: true) == .cloudChat,
                "a double-click in a group's empty part under a Cloud row is a Cloud composer too")
        #expect(rules.newWorkspace(machine: true, group: false, localWindow: false, windowDaemon: true, cloudMachine: true) == .cloudChat)
        // Any other machine keeps its own workspace (an SSH host's, a server's, this Mac's).
        #expect(rules.newWorkspace(machine: true, group: false, localWindow: true, windowDaemon: true) == .onMachine)
        // Cloud off by policy: the app lists no daemon for the machine, and the old rule decides, as before.
        #expect(rules.newWorkspace(machine: false, group: false, localWindow: true, windowDaemon: true, cloudMachine: true)
                == rules.newWorkspace(machine: false, group: false, localWindow: true, windowDaemon: true))
    }

    /// The bridge, end to end on this Mac's real daemon: the Cloud machine's section opens a workspace here, its one tab a
    /// chat whose seed picks Cloud, and asks the Cloud machine for nothing.
    @Test(.timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aDoubleClickUnderACloudRowOpensACloudComposerHere() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = services.agentTabs
        tabs.localHost = tabs.localHost ?? AgentSessionRef.host(installID: "cloud-section-test")
        tabs.holdsTabs = { _ in true }
        try #require(tabs.canHostChat, "this build has no agent page")
        let cloud = CloudTestLink.session(id: "vm-cloud-section", status: .running, name: "vm-cloud-section", mainWork: services.mainWork)
        services.machines.add(cloud)
        cloud.daemon.store.apply(snapshot: DaemonTree(registryID: "s-vm-cloud-section", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-cloud-chat"), name: "Cloud chat"),
        ]))
        let state = try #require(services.windows.active?.state)
        let store = services.daemon.store
        let before = Set(store.workspaces.map(\.id))
        let cloudBefore = cloud.daemon.store.workspaces.map(\.id)
        var newTabs: [ActionInvocation] = []
        _ = services.registry.bind("newTab", invoke: { newTabs.append($0) })

        SidebarBridge(services: services, state: state).handle(.newWorkspace(machine: MachineID(cloud.machineID), group: nil))
        let made = await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.workspaces.contains { !before.contains($0.id) } }
        let workspace = store.workspaces.first { !before.contains($0.id) }
        let tab = workspace?.screens.flatMap(\.panes).flatMap(\.tabs).first
        let seed = await tab.flatMap { tabs.seeds[AgentTabKey(machine: services.daemon.machineID, key: $0.id)] }?.peek()
        let cloudAfter = cloud.daemon.store.workspaces.map(\.id)
        await launched.stop()

        #expect(made, "no workspace opened on this Mac")
        #expect(tab?.kind == .conversation, "the new workspace's tab is \(String(describing: tab?.kind)), not a chat")
        #expect(seed?.picksCloud == true, "its composer does not have Cloud picked")
        #expect(cloudAfter == cloudBefore, "the Cloud machine got a workspace: \(cloudAfter)")
        #expect(newTabs.isEmpty, "it ran Cmd-N's New Workspace instead")
    }
    /// The issue's other half: a terminal in Cloud comes from Ctrl-` (New Terminal Tab) inside a Cloud workspace, which
    /// makes its tab on the daemon owning the focused pane (`TabLifecycle.newTerminal`, `AppServices.daemon(for:)`) under
    /// that workspace's key: the Cloud machine's, never this Mac's.
    @Test func ctrlBacktickInACloudWorkspaceTargetsTheCloudMachine() throws {
        let services = UnopenedCloudMachinesTests.services()
        let cloud = CloudTestLink.session(id: "vm-cloud-terminal", status: .running, name: "vm-cloud-terminal", mainWork: services.mainWork)
        services.machines.add(cloud)
        let pane = PaneSnapshot(id: PaneID(rawValue: 7), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 7), title: "chat")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        cloud.daemon.store.apply(snapshot: DaemonTree(registryID: "s-vm-cloud-terminal", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-cloud-terminal"), name: "Cloud chat", screens: [screen]),
        ]))
        let model = try #require(cloud.daemon.store.workspaces.first?.screens.first?.panes.first)

        #expect(services.daemon(for: model) === cloud.daemon, "a new terminal there would open on \(services.daemon(for: model).machineID)")
        #expect(services.workspaceKey(of: model)?.rawValue == "ws-cloud-terminal")
    }
}
