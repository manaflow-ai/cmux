@testable import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import Testing
@testable import CmuxNextApp

/// cmux#55668, seen in the dev build: a Mac tab whose New Tab page started a Cloud chat, then showed it in place,
/// kept reading "workspace-1" in the tab strip while its sidebar row took the chat's title. The strip names a chat
/// tab by `TabTitleResolver.untitled`, which read the Mac tab's own chat (no session: "Agent", then the workspace's
/// name), never the Cloud chat it shows. It now reads the shown chat's title.
@MainActor
struct CloudFrontedTabTitleTests {
    @Test func aMacTabShowingACloudChatInPlaceTakesThatChatsTitle() throws {
        func chat(_ surface: UInt64, host: String, session: String?) -> TabSnapshot {
            var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: "about:blank", url: "about:blank")
            tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: "claude"))
            return tab
        }
        let store = DaemonStore()
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [
            chat(1, host: "install:this-mac", session: nil), chat(2, host: "registry:cloud", session: "acp_cloud"),
        ])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [screen])]))
        let mac = try #require(store.tab(surface: 1)), cloud = try #require(store.tab(surface: 2))

        var strip = TabTitleResolver(newTabPages: [])
        strip.workspaceName = "workspace-1"
        strip.chatTitle = { $0.agentSession?.session == "acp_cloud" ? "Haiku about lighthouses" : AgentPaneModel.tabTitle }
        #expect(strip.untitled(mac) == "workspace-1", "fixture: a Mac tab showing nothing reads its workspace's name")

        strip.fronted = { $0.id == mac.id ? cloud : nil }
        #expect(strip.untitled(mac) == "Haiku about lighthouses", "the Mac tab read its own chat, not the Cloud chat it shows")
        #expect(strip.title(mac) == "Haiku about lighthouses")
    }
}
