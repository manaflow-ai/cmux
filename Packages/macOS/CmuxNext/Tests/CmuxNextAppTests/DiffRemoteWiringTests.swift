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
    /// AppServices reads `NSApp` (an implicitly unwrapped Optional) from its observers and services;
    /// a suite run in its own process has no shared application until something makes it.
    init() { _ = NSApplication.shared }

    @Test func localRuntimeRetainsBundledSidecarAndRemoteDisablesIt() {
        #expect(DiffPageRuntime.sidecarArgument(isLocal: true) == nil)
        #expect(DiffPageRuntime.sidecarArgument(isLocal: false) != nil)
    }

    @Test func unresolvedRemoteChatDoesNotFallBackToLocalGitLink() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
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
        #expect(service.gitLink(for: try #require(services.daemon.store.tab(idOrResource: id))) == nil)
        #expect(service.gitLink(for: nil) === services.agentGit.local)
    }

    /// Open Diff from a Cloud workspace's pane (#25581) reads on the pane's machine unless the
    /// selected tab is a chat whose session runs elsewhere (#26113): a chat this Mac runs reads
    /// this Mac, a refused one stays refused, and only a chat on the pane's machine joins it.
    @Test func aCloudPaneReadsOnItsMachineOnlyWhenTheSelectedChatRunsThere() throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.agentTabs.localHost = "install:this-mac"
        let cloud = CloudMoveTests.machine(services, cli: URL(fileURLWithPath: "/usr/bin/false"),
                                           root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        services.machines.add(cloud)
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 1), tabResourceID: ResourceID(rawValue: "chat"),
                               kind: .conversation, title: "Chat")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:dev-vm"))
        var localChat = TabSnapshot(surface: 3, tabResourceID: "local-chat", kind: .conversation, title: "Local chat")
        localChat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:this-mac"))
        var refusedChat = TabSnapshot(surface: 4, tabResourceID: "refused-chat", kind: .conversation, title: "Refused chat")
        refusedChat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:another-registry"))
        let terminal = TabSnapshot(surface: SurfaceID(rawValue: 2), tabResourceID: ResourceID(rawValue: "terminal"),
                                   kind: .pty, title: "Terminal")
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [chat, terminal, localChat, refusedChat])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        cloud.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "cloud", screens: [screen])]))
        let machineLink = services.agentGit.link(for: cloud.daemon)
        let service = DiffPageService(services: services)

        #expect(service.readsOnPaneMachine(machineLink, selected: nil))
        #expect(service.readsOnPaneMachine(machineLink, selected: try #require(cloud.daemon.store.tab(idOrResource: "terminal"))))
        #expect(service.readsOnPaneMachine(machineLink, selected: try #require(cloud.daemon.store.tab(idOrResource: "chat"))))
        let local = try #require(cloud.daemon.store.tab(idOrResource: "local-chat"))
        #expect(!service.readsOnPaneMachine(machineLink, selected: local))
        #expect(service.gitLink(for: local) === services.agentGit.local)
        let refused = try #require(cloud.daemon.store.tab(idOrResource: "refused-chat"))
        #expect(!service.readsOnPaneMachine(machineLink, selected: refused))
        #expect(service.gitLink(for: refused) == nil)
    }

    @Test(arguments: [true, false])
    func aForkedChatStillRefusesAnotherRegistry(resourceIDs: Bool) throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cloud = CloudMoveTests.machine(services, cli: URL(fileURLWithPath: "/usr/bin/false"),
                                           root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        services.machines.add(cloud)
        var chat = TabSnapshot(surface: 1, tabResourceID: resourceIDs ? "forked-chat" : nil,
                               kind: .conversation, title: "Forked chat")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:other-registry"))
        let pane = PaneSnapshot(id: 1, tabs: [chat])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        let tree = DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Forked", screens: [screen])])
        services.daemon.store.apply(snapshot: tree)
        cloud.daemon.store.apply(snapshot: tree)
        let selected = try #require(cloud.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        #expect(services.locateTab(selected.id) == nil)
        services.agentTabs.gitLink = { _ in nil }
        let service = DiffPageService(services: services)
        #expect(!service.readsOnPaneMachine(services.agentGit.link(for: cloud.daemon), selected: selected))
        #expect(service.gitLink(for: selected) == nil)

        // The same ID on another machine must not shadow a valid chat on this VM either.
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:dev-vm"))
        let ownPane = PaneSnapshot(id: 1, tabs: [chat])
        let ownScreen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [ownPane])
        cloud.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Forked", screens: [ownScreen])]))
        let ownChat = try #require(cloud.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let localChat = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let machineLink = services.agentGit.link(for: cloud.daemon)
        #expect(service.gitLink(for: ownChat) === machineLink)
        #expect(service.readsOnPaneMachine(machineLink, selected: ownChat))
        #expect(service.gitLink(for: localChat) == nil)
        cloud.daemon.store.apply(snapshot: DaemonTree())
        #expect(service.gitLink(for: ownChat) == nil)
    }
}
