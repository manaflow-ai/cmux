import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
import Foundation
import Testing

/// `cmux cloud start-session` (and `cmux chat --on vm:…`, which runs it) opened its chat in the machine's first
/// workspace beside the image's starter shell, or made one with a terminal when the machine had none
/// (`CloudHandlers.terminalAnchor`). A CLI-started chat now gets the chat's own workspace, made with the chat as
/// its first and only tab, as the composer's Cloud start does.
@MainActor @Suite(.serialized)
struct CloudStartSessionChatOnlyTests {
    private func shell(_ surface: UInt64) -> TabSnapshot { TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .pty, title: "~") }

    private func chat(_ surface: UInt64) -> TabSnapshot {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, cwd: nil)
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:s-vm", session: nil, harness: nil))
        return tab
    }

    private func workspace(_ handle: UInt64, key: WorkspaceKey, tabs: [TabSnapshot]) -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: PaneID(rawValue: handle), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: handle), layout: .leaf(PaneID(rawValue: handle)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: handle), key: key, name: "workspace-\(handle)", screens: [screen])
    }

    @Test func aCLIStartedChatsWorkspaceHasTheChatAsItsOnlyTab() async throws {
        let f = CloudCLITargetTests.fixture(), store = f.session.daemon.store
        let starter = workspace(1, key: WorkspaceKey(rawValue: "ws-from-the-image"), tabs: [shell(10)])
        _ = store.apply(.connected(DaemonIdentity(generation: "live"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [starter]))
        var made: [WorkspaceKey] = []
        let (anchor, opened) = try await CloudStartSession.chatWorkspace("cloud-start-session-k1", on: f.session, notConnected: ActionFailure(message: "not connected"),
                                                                         open: { _ in Issue.record("nothing to reopen"); return nil }) { key in
            // The daemon makes the workspace with the chat as its first tab (createWithFirstTab) and lists it.
            made.append(key)
            store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [starter, workspace(2, key: key, tabs: [chat(20)])]))
            return SurfaceID(rawValue: 20)
        }
        #expect(made == [CloudMachineWorkspace.chatKey(tabKey: "cloud-start-session-k1")])
        #expect(anchor.id != "ws-from-the-image", "the chat opened in the machine's first workspace, beside its shell")
        let kinds = store.workspaces.first { $0.id == anchor.id }?.screens.flatMap(\.panes).flatMap(\.tabs).map(\.kind)
        #expect(kinds == [.conversation], "the chat's workspace has a tab beside the chat: \(String(describing: kinds))")
        #expect(opened.surface == SurfaceID(rawValue: 20))
        #expect(anchor.pane.tabs.map(\.id) == [opened.key])
    }
}
