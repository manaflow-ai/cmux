import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// ask-8d11bc20e5 (Leo 2026-11-22: "BUT WHO IS MANGO? ... MAYBE YOU GUYS SHUOLD BE ABLE TO SET
/// CUSTOM ICONS FOR YOURSELVES IN THE TABS"): a chat's given name (acpmux `displayName`) is its
/// title on every native surface, and the icon it gave itself (acpmux `icon`) is its tab's.
@MainActor
struct AgentIdentitySurfacesTests {
    static let host = "install:agent-identity"

    static func chatTab(_ session: String, harness: String) -> TabModel {
        var snapshot = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        snapshot.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: harness))
        return TabModel(snapshot)
    }

    @Test func aGivenNameIsTheChatsTitle() {
        let summary: [String: Any] = ["sessionId": "s1", "name": "claude-sr2-coord-old", "displayName": "Mango",
                                      "harness": "claude", "title": "Coordinate the lanes"]
        #expect(AgentTurnStates.title(summary) == "Mango")
        // Workspace auto-naming reads the chat's real title, never a name.
        #expect(AgentTurnStates.title(summary, includingPrompt: false) == nil)
        var unnamed = summary
        unnamed["displayName"] = "  "
        #expect(AgentTurnStates.title(unnamed) == "claude-sr2-coord-old")
    }

    @Test func aSummaryCarriesTheChatsOwnIcon() throws {
        let detail = try #require(AgentChatDetail.of(summary: ["icon": ["kind": "emoji", "text": "🥭", "source": "session"]]))
        #expect(detail.icon == .emoji("🥭", isOwn: false))
        // A site's favicon is often an ICO: it parses, as PNG and SVG do.
        let ico = Data([0, 0, 1, 0, 1, 0]).base64EncodedString()
        #expect(HarnessIconSpec(json: ["kind": "image", "mime": "image/x-icon", "data": ico]) != nil)
        #expect(HarnessIconSpec(json: ["kind": "image", "mime": "image/gif", "data": ico]) == nil)
    }

    @Test func aChatsOwnIconIsItsTabIcon() {
        let turns = AgentTurnStateStore()
        turns.localHost = Self.host
        let harnessIcons = HarnessIconArtwork().lookup(for: HarnessIcons(harnessesReply: ["harnesses": [
            "fox": ["iconSpec": ["kind": "emoji", "text": "🦊", "source": "profile"]],
        ]]))
        let tab = Self.chatTab("s-mango", harness: "fox")
        func icon() -> TabIcon {
            TabItemMapping.shared.item(tab, fallbackTitle: "Chat", turns: turns, harnessIcons: harnessIcons).icon
        }
        let harnessOwn = icon()
        guard case .image = harnessOwn else { Issue.record("before the chat sets one, its harness's icon: \(harnessOwn)"); return }

        let own = HarnessIconSpec.symbol("leaf.fill", monogram: "M", hue: 30, isOwn: false)
        turns.apply(session: "s-mango", state: nil, lastMessage: nil, muted: false, title: "Mango",
                    detail: AgentChatDetail(icon: own))
        #expect(icon() == .symbol("leaf.fill"), "the chat's own icon beats its harness's")

        turns.apply(session: "s-mango", state: nil, lastMessage: nil, muted: false, title: "Mango",
                    detail: AgentChatDetail(icon: .emoji("🥭", isOwn: false)))
        let mango = icon()
        guard case .image = mango else { Issue.record("an emoji draws as an image: \(mango)"); return }
        #expect(mango == icon(), "the same icon keeps its image")
        #expect(mango != harnessOwn)
    }
}
