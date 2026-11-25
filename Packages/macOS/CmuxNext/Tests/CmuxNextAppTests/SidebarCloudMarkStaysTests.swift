@testable import CmuxNextBridge
@testable import CmuxNextDaemon
import Testing

/// cmux#55668 (Austin 2026-11-24): "i dont see a cloud next to the workspace if it is a cloud workspace ... it like
/// disappears". The row read its cloud mark from its face tab alone, so it went whenever another tab of the workspace (a
/// second chat, a terminal, a page) became the face, and came back only if the Cloud chat fronted it again. Any Cloud chat
/// of the workspace now marks its row, whatever the face.
@MainActor
struct SidebarCloudMarkStaysTests {
    /// A workspace with a local chat (pane 1, focused last: the face) and a Cloud chat beside it (pane 2).
    private static func workspace() throws -> WorkspaceModel {
        func chat(_ surface: UInt64, session: String) -> TabSnapshot {
            var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: "about:blank", url: "about:blank")
            tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:this-mac", session: session, harness: "claude"))
            return tab
        }
        let local = PaneSnapshot(id: 1, focusedAt: 2, tabs: [chat(1, session: "local-chat")])
        let cloud = PaneSnapshot(id: 2, focusedAt: 1, tabs: [chat(2, session: "cloud-chat")])
        let screen = ScreenSnapshot(id: 1, layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1), b: .leaf(2)),
                                    panes: [local, cloud])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 284, key: nil, name: "workspace-284", screens: [screen])]))
        return try #require(store.workspaces.first)
    }

    @Test func aCloudChatBesideTheFaceKeepsTheRowsCloud() throws {
        let workspace = try Self.workspace()
        let cloudTab = try #require(workspace.screens.flatMap(\.panes).flatMap(\.tabs).first { $0.agentSession?.session == "cloud-chat" })
        // `AppServices.sidebarPageFace`: only the Cloud chat (shown in place, or starting) reads as Cloud.
        var asked: [String] = []
        let row = SidebarMapping.shared.row(workspace, machine: .local, pageFace: { _, tab, _ in
            asked.append(tab.id)
            return .init(startsInCloud: tab.id == cloudTab.id)
        })
        #expect(asked.first != cloudTab.id, "fixture: the face is the local chat")
        #expect(row.startsInCloud, "the row's cloud went when another tab was its face")

        let plain = SidebarMapping.shared.row(workspace, machine: .local, pageFace: { _, _, _ in .init() })
        #expect(!plain.startsInCloud, "a workspace with no Cloud chat draws no cloud")
    }
}
