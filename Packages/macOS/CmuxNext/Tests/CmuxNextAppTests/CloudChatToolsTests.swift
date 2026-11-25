import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextRemoteView
import CmuxNextTabs
import Foundation
import Testing

/// A Cloud chat's Terminal and Browser open on its Cloud machine, never on this Mac (cmux#55413).
@MainActor @Suite(.serialized)
struct CloudChatToolsTests {
    /// A Cloud chat a Mac tab shows in place (CloudFrontedChats): its Browser and Terminal go to its machine (here one
    /// with no desktop, which says so) and never fall back to a tab on this Mac; this Mac's chats keep the local route.
    @Test func theHeaderToolsOfACloudChatTargetTheCloudMachine() {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        let session = MachineIconTests.cloudMachine(services, id: "vm-tools-\(UUID().uuidString.prefix(8))")
        let chat = AgentTabKey(machine: session.machineID, key: "chat-1"), local = services.machines.local.machineID
        services.agentTabs.frontedChats.front(AgentTabKey(machine: local, key: "mac-1"),
                                              with: CloudFrontedChats.Front(machine: session.machineID, key: chat.key, workspace: "ws-chat"))
        var browser: Bool?, terminal: Bool?
        let refusal = services.registry.capturingRefusal {
            browser = CloudFrontedChats.openTool(.browser, chat: chat, cwd: nil, services: services)
        }
        #expect(browser == true)
        #expect(refusal == CloudStrings.desktopUnavailable(session.machine.title))
        _ = services.registry.capturingRefusal { terminal = CloudFrontedChats.openTool(.terminal, chat: chat, cwd: "/root/app", services: services) }
        #expect(terminal == true, "the terminal opens on the machine, not as a split of this Mac's tab")
        #expect(CloudFrontedChats.openTool(.browser, chat: AgentTabKey(machine: local, key: "chat-2"), cwd: nil, services: services) == nil)
        #expect(CloudFrontedChats.openTool(.terminal, chat: AgentTabKey(machine: local, key: "chat-2"), cwd: "/tmp", services: services) == nil)
    }

    /// A Cloud chat in its machine's own workspace: its Terminal is the pane's own split, on the machine already, and a
    /// machine with no desktop keeps the pane's browser tab (never only a refusal).
    @Test func aCloudChatInItsMachinesWorkspaceKeepsItsPanesTools() {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        let session = MachineIconTests.cloudMachine(services, id: "vm-pane-\(UUID().uuidString.prefix(8))")
        let chat = AgentTabKey(machine: session.machineID, key: "chat-1")
        #expect(CloudFrontedChats.openTool(.terminal, chat: chat, cwd: nil, services: services) == nil)
        #expect(CloudFrontedChats.openTool(.browser, chat: chat, cwd: nil, services: services) == nil)
    }

    /// A Cloud chat's Files opens its folder on the machine, read through the machine's daemon, beside the Mac tab that
    /// shows the chat in place; this Mac's chats keep this Mac's tree. Before, a Cloud chat's Files opened nothing.
    @Test func theFilesOfACloudChatOpenTheMachinesTree() throws {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-files-\(UUID().uuidString.prefix(8))")
        var tab = TabSnapshot(surface: SurfaceID(rawValue: 1), tabResourceID: "chat-files", kind: .conversation, cwd: "/home/cmux/chats/r1")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "", session: "s-files", harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        session.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: "ws-files", name: "VM", screens: [screen])]))
        let remote = services.agentGit.link(for: session.daemon)
        services.agentTabs.gitLinkScoped = { [services] key in key.key == "chat-files" ? remote : services.agentGit.local }
        let chat = AgentTabKey(machine: session.machineID, key: "chat-files")

        let inItsWorkspace = try #require(CloudFrontedChats.filesPlace(chat, services: services))
        #expect(inItsWorkspace.link === remote, "the tree reads the machine's folder, never this Mac's")
        #expect(inItsWorkspace.machine === session.daemon)
        #expect(inItsWorkspace.beside == "chat-files")

        let mac = AgentTabKey(machine: services.machines.local.machineID, key: "mac-files")
        services.agentTabs.frontedChats.front(mac, with: CloudFrontedChats.Front(machine: session.machineID, key: "chat-files", workspace: "ws-files"))
        #expect(try #require(CloudFrontedChats.filesPlace(chat, services: services)).beside == "mac-files",
                "a chat a Mac tab shows in place opens its tree beside that tab, in a window")

        let local = try #require(CloudFrontedChats.filesPlace(AgentTabKey(machine: services.machines.local.machineID, key: "local-chat"), services: services))
        #expect(local.link === services.agentGit.local && local.machine == nil && local.beside == "local-chat")
        // The same tab id on another machine is not this chat: no tree of the wrong machine.
        #expect(CloudFrontedChats.filesPlace(AgentTabKey(machine: "vm-other", key: "chat-files"), services: services) == nil)
        services.agentTabs.gitLinkScoped = { _ in nil }
        #expect(CloudFrontedChats.filesPlace(chat, services: services) == nil)
    }

    /// Split Down on a Cloud chat a Mac tab shows in place opens its terminal on the machine, in the chat's folder, never as a
    /// split of this Mac's tab; any other chat (the Cloud route says no) keeps its own split, as do the other header actions.
    @Test func splitDownOfAFrontedCloudChatOpensOnTheMachine() {
        var asked: [String?] = [], routes = true
        var actions = AgentChatTabActions(tab: { "chat-1" }, machine: "vm-1", registry: { nil }, local: { false })
        actions.cloudTerminal = { cwd in asked.append(cwd); return routes }
        actions.run("splitDown", cwd: "/root/app")
        #expect(asked == ["/root/app"], "Split Down goes to the machine with the chat's folder")
        actions.run("splitDown", cwd: "/root/app", on: "other-tab")
        actions.run("splitBrowserRight", cwd: nil)
        #expect(asked.count == 1, "a split of another tab and the other actions never take the Cloud terminal route")
        routes = false
        actions.run("splitDown", cwd: nil)
        #expect(asked.count == 2, "a chat that is not fronted asks, then keeps its own split")
    }

    /// The desktop a Cloud chat's Browser opens is the machine's own `cmux-rd` desktop over its carrier, which every
    /// build connects to (``RemoteViewTabPolicy``), the record Open Desktop opens.
    @Test func theBrowserOpensTheMachinesCarrierDesktop() throws {
        let services = MachineIconTests.services()
        var machine = CloudMachine(id: "VM-Desk1", capabilities: CloudMachine.Capabilities(exec: true, desktop: true))
        machine.provider = "cmux-next"
        machine.servesDesktop = true
        let session = CloudMachineSession(machine: machine, appLink: CloudTestLink.session(id: "VM-Desk1", name: "Desk").appLink,
                                          localIdentity: { nil }, mainWork: services.mainWork)
        let record = try CloudHandlers.desktopRecord(session)
        #expect(record.host == "vm-desk1")
        #expect(record.cloudDesktop && record.cloudRd)
        #expect(record.mode == .view, "it opens watching the agent; control is the person's Take over")
        #expect(RemoteViewTabPolicy().decide(record: record, source: .person, paneAvailable: false, cloudRdAvailable: true) == .connect(record))
    }
}
