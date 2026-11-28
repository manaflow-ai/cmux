import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
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
