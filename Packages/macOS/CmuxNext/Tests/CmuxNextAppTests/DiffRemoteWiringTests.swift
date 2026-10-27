import AppKit
import CmuxNextAgentPane
import CmuxNextDaemonService
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDiff

/// The full Diff tab keeps local sidecar availability and refuses a remote chat when its daemon
/// link cannot be resolved. The latter must never fall through to this Mac's same-path checkout.
@MainActor
@Suite(.serialized)
struct DiffRemoteWiringTests {
    /// The app's services, with the shared application they read (`NSApp`) made first.
    private static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    /// The selected chat's session link, set by each step of a test.
    @MainActor private final class ChatLink {
        var link: AgentPaneGitLink?
    }

    @Test func localRuntimeRetainsBundledSidecarAndRemoteDisablesIt() {
        #expect(DiffPageRuntime.sidecarArgument(isLocal: true) == nil)
        #expect(DiffPageRuntime.sidecarArgument(isLocal: false) != nil)
    }

    @Test func unresolvedRemoteChatDoesNotFallBackToLocalGitLink() {
        let services = Self.services()
        let id = "remote-diff-chat"
        var tab = TabSnapshot(surface: SurfaceID(rawValue: 1), tabResourceID: ResourceID(rawValue: id),
                              kind: .conversation, title: "Remote")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:other-machine"))
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [tab])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        let workspace = WorkspaceSnapshot(id: 1, key: nil, name: "remote", screens: [screen])
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [workspace]))
        services.agentTabs.gitLink = { _ in nil }

        let service = DiffPageService(services: services)
        #expect(service.gitLink(for: id) == nil)
        #expect(service.gitLink(for: nil) === services.agentGit.local)
    }

    /// Open Diff from a Cloud workspace's pane (#25581) reads on the pane's machine unless the
    /// selected tab is a chat whose session runs elsewhere (#26113): a chat this Mac runs reads
    /// this Mac, a refused one stays refused, and only a chat on the pane's machine joins it.
    @Test func aCloudPaneReadsOnItsMachineOnlyWhenTheSelectedChatRunsThere() {
        let services = Self.services()
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 1), tabResourceID: ResourceID(rawValue: "chat"),
                               kind: .conversation, title: "Chat")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:dev-vm"))
        let terminal = TabSnapshot(surface: SurfaceID(rawValue: 2), tabResourceID: ResourceID(rawValue: "terminal"),
                                   kind: .pty, title: "Terminal")
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [chat, terminal])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "cloud", screens: [screen])]))
        let machineLink = AgentPaneGitLink(daemon: services.daemon)
        let chatLink = ChatLink()
        services.agentTabs.gitLink = { _ in chatLink.link }
        let service = DiffPageService(services: services)

        #expect(service.readsOnPaneMachine(machineLink, selected: nil))
        #expect(service.readsOnPaneMachine(machineLink, selected: "terminal"))
        chatLink.link = machineLink
        #expect(service.readsOnPaneMachine(machineLink, selected: "chat"))
        chatLink.link = services.agentGit.local
        #expect(!service.readsOnPaneMachine(machineLink, selected: "chat"))
        chatLink.link = nil
        #expect(!service.readsOnPaneMachine(machineLink, selected: "chat"))
        machineLink.close()
    }
}
