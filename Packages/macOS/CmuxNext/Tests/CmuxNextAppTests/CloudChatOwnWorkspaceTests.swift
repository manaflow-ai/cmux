import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
import Foundation
import Testing

/// 2026-11-10: a Cloud chat opened in the machine's first workspace ("workspace-1") beside a starter terminal
/// (`~/work/chats/<id>`): `CloudStartChat` anchored the chat with `CloudHandlers.terminalAnchor`, which takes the
/// machine's first workspace or makes one with a terminal (`WindowManager.createWorkspace(on:)`). A chat start now
/// gets a workspace of its own, made with the chat as its first tab, and no terminal is made for it. A terminal the
/// person opens there later is an ordinary tab of that workspace.
@MainActor @Suite(.serialized)
struct CloudChatOwnWorkspaceTests {
    static let notConnected = ActionFailure(message: "not connected")

    private func connectedStore(_ workspaces: [WorkspaceSnapshot]) -> DaemonStore {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "live"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: workspaces))
        return store
    }

    private func shell(_ surface: UInt64) -> TabSnapshot { TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .pty, title: "~/work/chats/abc") }

    private func chat(_ surface: UInt64) -> TabSnapshot {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, cwd: nil)
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:s-vm", session: nil, harness: nil))
        return tab
    }

    private func workspace(_ handle: UInt64, key: WorkspaceKey, tabs: [TabSnapshot]) -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: PaneID(rawValue: handle), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: handle), layout: .leaf(PaneID(rawValue: handle)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: handle), key: key, name: "workspace-\(handle)", screens: tabs.isEmpty ? [] : [screen])
    }

    /// The machine's first workspace, with its starter shell, is never the chat's: the start makes its own.
    @Test func aChatStartMakesItsOwnWorkspaceNotTheMachinesFirst() async throws {
        let store = connectedStore([workspace(1, key: WorkspaceKey(rawValue: "ws-from-the-image"), tabs: [shell(10)])])
        var made: [WorkspaceKey] = [], opened: [WorkspaceHandle] = []
        let result = try await CloudMachineWorkspace.chat(tabKey: "cloud-start-chat-k1", in: store, notConnected: Self.notConnected,
                                                          open: { opened.append($0); return "reopened" }) { made.append($0); return "chat" }
        #expect(result.created && result.tab == "chat" && opened.isEmpty)
        #expect(made == [CloudMachineWorkspace.chatKey(tabKey: "cloud-start-chat-k1")])
        #expect(result.key.rawValue != "ws-from-the-image")
    }

    /// A retry of the same start finds its workspace, makes nothing (no second workspace, no terminal) and opens its chat there.
    @Test func aRetryFindsItsWorkspaceAndMakesNothing() async throws {
        let key = CloudMachineWorkspace.chatKey(tabKey: "cloud-start-chat-k1")
        let store = connectedStore([workspace(1, key: WorkspaceKey(rawValue: "ws-from-the-image"), tabs: [shell(10)]),
                                    workspace(2, key: key, tabs: [chat(20)])])
        var made = 0, opened: [WorkspaceHandle] = []
        let result = try await CloudMachineWorkspace.chat(tabKey: "cloud-start-chat-k1", in: store, notConnected: Self.notConnected,
                                                          open: { opened.append($0); return "same tab" }) { _ in made += 1; return "new" }
        #expect(!result.created && result.key == key && made == 0)
        #expect(opened == [WorkspaceHandle(rawValue: 2)] && result.tab == "same tab", "a retry opened its chat somewhere else")
    }

    /// The key is a UUID (acpmux names a session's display only for a UUID workspace key), fixed per start.
    @Test func theKeyIsAStableUUIDPerStart() {
        let one = CloudMachineWorkspace.chatKey(tabKey: "cloud-start-chat-k1")
        #expect(UUID(uuidString: one.rawValue) != nil)
        #expect(one == CloudMachineWorkspace.chatKey(tabKey: "cloud-start-chat-k1"))
        #expect(one != CloudMachineWorkspace.chatKey(tabKey: "cloud-start-chat-k2"))
    }

    /// The chat's workspace lists only the chat; a terminal the person opens there later is listed with it (nothing
    /// filters terminals out of a Cloud workspace).
    @Test func aTerminalThePersonAddsLaterShows() throws {
        let key = CloudMachineWorkspace.chatKey(tabKey: "cloud-start-chat-k1")
        let store = connectedStore([workspace(2, key: key, tabs: [chat(20)])])
        let kinds = { store.workspaces.first { $0.key == key }?.screens.flatMap(\.panes).flatMap(\.tabs).map(\.kind) }
        #expect(kinds() == [.conversation], "the chat's workspace has a starter terminal")
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [workspace(2, key: key, tabs: [chat(20), shell(21)])]))
        #expect(kinds() == [.conversation, .pty], "a terminal the person opened is missing")
    }
}
