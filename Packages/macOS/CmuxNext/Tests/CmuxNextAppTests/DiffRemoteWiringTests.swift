import AppKit
import CmuxNextAgentPane
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

    @Test func unresolvedRemoteChatDoesNotFallBackToLocalGitLink() {
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
        #expect(service.gitLink(for: id) == nil)
        #expect(service.gitLink(for: nil) === services.agentGit.local)
    }
}
