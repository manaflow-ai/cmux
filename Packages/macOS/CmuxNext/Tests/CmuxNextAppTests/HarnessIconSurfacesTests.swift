import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import Testing

/// User 12922: a custom harness's own icon (`iconSpec` on `_acpmux/harnesses`) draws on the native
/// surfaces too: the chat's tab in the tab strip and its workspace's sidebar row. A profile's own
/// icon wins over the mark its id suggests; acpmux's pick (a detected brand, a monogram) shows for
/// a harness no mark names; an id that names a mark keeps it when the profile sets none.
@MainActor
struct HarnessIconSurfacesTests {
    static let host = "install:harness-icons"

    static func chatSnapshot(_ harness: String, surface: UInt64 = 1) -> TabSnapshot {
        var snapshot = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, cwd: nil)
        snapshot.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: "s-\(harness)", harness: harness))
        return snapshot
    }

    static let reply: [String: Any] = ["harnesses": [
        "fox": ["iconSpec": ["kind": "emoji", "text": "🦊", "source": "profile"]],
        "hammer": ["iconSpec": ["kind": "symbol", "name": "hammer.fill", "text": "H", "hue": 10, "source": "profile"]],
        "my-gem": ["iconSpec": ["kind": "brand", "brand": "gemini", "source": "command"]],
        "zeta-bot": ["iconSpec": ["kind": "monogram", "text": "ZB", "hue": 37, "source": "default"]],
        "claude-sr2": ["iconSpec": ["kind": "emoji", "text": "🐙", "source": "profile"]],
        "claude": ["iconSpec": ["kind": "brand", "brand": "claude", "source": "id"]],
    ]]
    let artwork = HarnessIconArtwork()
    var icons: HarnessIconLookup { artwork.lookup(for: HarnessIcons(harnessesReply: Self.reply)) }

    func tabIcon(_ harness: String, icons: HarnessIconLookup? = nil) -> TabIcon {
        TabItemMapping.shared.item(TabModel(Self.chatSnapshot(harness)), fallbackTitle: "Chat", harnessIcons: icons ?? self.icons).icon
    }

    @Test func aChatTabDrawsItsHarnessIcon() {
        // The same list draws the same images: a snapshot that draws them again redraws nothing.
        #expect(tabIcon("fox") == tabIcon("fox"))
        guard case .image = tabIcon("fox") else { Issue.record("an emoji draws as an image: \(tabIcon("fox"))"); return }
        guard case .image = tabIcon("zeta-bot") else { Issue.record("a monogram draws as an image: \(tabIcon("zeta-bot"))"); return }
        guard case .image = tabIcon("claude-sr2") else { Issue.record("its own icon beats the id's mark"); return }
        #expect(tabIcon("hammer") == .symbol("hammer.fill"))
        #expect(tabIcon("my-gem") == .agentMark("gemini"))
        #expect(tabIcon("claude") == .agentMark("claude"))
        // Before the list is read: the kind icon, never a blank.
        #expect(tabIcon("fox", icons: HarnessIconLookup.none) == tabIcon("unknown-harness", icons: HarnessIconLookup.none))
    }

    @Test func aWorkspaceRowDrawsItsChatsHarnessIcon() throws {
        func row(_ harness: String) throws -> SidebarWorkspace {
            let store = DaemonStore()
            let pane = PaneSnapshot(id: 1, tabs: [Self.chatSnapshot(harness)])
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
            store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
            let workspace = try #require(store.workspaces.first)
            return SidebarMapping.shared.row(workspace, machine: .local, harnessIcons: icons)
        }
        guard case .image = try row("fox").agentIcon else { Issue.record("the row draws the emoji"); return }
        #expect(try row("hammer").agentIcon == .symbol("hammer.fill"))
        #expect(try row("my-gem").agentBrand == "gemini")
        #expect(try row("claude").agentIcon == nil)
        #expect(try row("claude").agentBrand == "claude")
    }
}
