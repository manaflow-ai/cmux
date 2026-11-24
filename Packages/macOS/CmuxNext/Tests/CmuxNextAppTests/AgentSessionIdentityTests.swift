@testable import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextApp

/// Leo: "BUT WHO IS MANGO? ... RENAMES NEED TO BE PROPAGATED TO THE VISIBLE AREAS AND IT SHOULD ALL BE
/// REFLECTED ... SET CUSTOM ICONS FOR YOURSELVES IN THE TABS. SYMBOLS, SVGS, EMOJIS, FAVICONS". acpmux's
/// SessionSummary carries `displayName`, `formerNames` and `icon`; the tab, its hover card and the sidebar
/// row read them as they come.
@MainActor
struct AgentSessionIdentityTests {
    static let host = "install:session-identity"

    static func chatSnapshot(_ harness: String, session: String) -> TabSnapshot {
        var snapshot = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        snapshot.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: harness))
        return snapshot
    }

    static func store() -> AgentTurnStateStore {
        let turns = AgentTurnStateStore()
        turns.localHost = host
        return turns
    }

    // MARK: Decoding

    @Test func eachIconKindDecodes() throws {
        func icon(_ json: [String: Any]) -> HarnessIconSpec? {
            AgentSessionIdentity.of(summary: ["sessionId": "s", "icon": json])?.icon
        }
        #expect(icon(["kind": "emoji", "text": "🥭", "source": "session"]) == .emoji("🥭", isOwn: false))
        #expect(icon(["kind": "symbol", "name": "leaf.fill", "text": "M", "hue": 40, "source": "session"])
                == .symbol("leaf.fill", monogram: "M", hue: 40, isOwn: false))
        #expect(icon(["kind": "brand", "brand": "claude", "source": "session"]) == .brand("claude", isOwn: false))
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        #expect(icon(["kind": "image", "mime": "image/svg+xml", "data": svg.base64EncodedString(), "source": "session"])
                == .image(svg, mime: "image/svg+xml", isOwn: false))
        #expect(icon(["kind": "image", "mime": "image/gif", "data": svg.base64EncodedString()]) == nil, "only PNG and SVG")
        #expect(AgentSessionIdentity.of(summary: ["sessionId": "s", "name": "plain"]) == nil, "an older acpmux sends none")
    }

    @Test func theNameAndFormerNamesDecode() throws {
        let identity = try #require(AgentSessionIdentity.of(summary: [
            "sessionId": "s", "displayName": "Mango", "formerNames": ["first", "claude-sr2-coord-old"],
        ]))
        #expect(identity.displayName == "Mango")
        #expect(identity.formerName == "claude-sr2-coord-old", "the newest former name")
        #expect(AgentSessionIdentity.of(summary: ["sessionId": "s", "displayName": "  "]) == nil, "a blank name is none")
    }

    // MARK: Titles

    @Test func theGivenNameWinsTheTabTitle() {
        let summary: [String: Any] = ["sessionId": "s", "name": "launcher-name", "harness": "claude", "displayName": "Mango",
                                      "title": "Fix the sidebar", "titleSource": "generated"]
        #expect(AgentTurnStates.title(summary) == "Mango")
        #expect(AgentTurnStates.title(summary, includingPrompt: false) == "Fix the sidebar", "the real title stays the chat's own")

        let turns = Self.store()
        let ref = AgentSessionRef(host: Self.host, session: "mango", harness: "claude")
        turns.apply(session: "mango", state: nil, lastMessage: nil, muted: false, title: AgentTurnStates.title(summary),
                    identity: AgentSessionIdentity.of(summary: summary), detail: nil)
        #expect(AgentChatTabTitle.untitled(ref, turns: turns) == "Mango")
        #expect(turns.displayName(for: ref) == "Mango")
    }

    @Test func theSidebarRowReadsTheGivenNameButAPersonsRenameWins() {
        let auto = SidebarMapping.agentRowTitle(workspaceTitle: "workspace-3", workspaceName: "workspace-3", workspaceNameSource: .auto,
                                                sessionName: nil, displayName: "Mango", chatTitle: "Fix the sidebar", taskSummary: nil)
        #expect(auto == "Mango")
        let tabNamed = SidebarMapping.agentRowTitle(workspaceTitle: "workspace-3", workspaceName: "workspace-3", workspaceNameSource: .auto,
                                                    sessionName: nil, displayName: "Mango", chatTitle: nil,
                                                    explicitChatTitle: "My chat", taskSummary: nil)
        #expect(tabNamed == "My chat", "the person's tab name wins")
        let renamed = SidebarMapping.agentRowTitle(workspaceTitle: "Release", workspaceName: "Release", workspaceNameSource: .user,
                                                   workspaceNameRevision: 2, sessionName: nil, displayName: "Mango",
                                                   chatTitle: nil, taskSummary: nil)
        #expect(renamed == "Release", "the person's workspace rename wins")
    }

    @Test func theHoverCardNamesTheFormerName() {
        let turns = Self.store()
        turns.apply(session: "mango", state: nil, lastMessage: nil, muted: false, title: "Mango",
                    identity: AgentSessionIdentity(displayName: "Mango", formerNames: ["claude-sr2-coord-old"]), detail: nil)
        let item = TabItemMapping.shared.item(TabModel(Self.chatSnapshot("claude", session: "mango")), fallbackTitle: "Mango", turns: turns)
        #expect(item.hover.formerName == "claude-sr2-coord-old")
    }

    // MARK: Icons

    @Test func theSessionsIconWinsOverItsHarnessIcon() throws {
        let reply: [String: Any] = ["harnesses": [
            "hammer": ["iconSpec": ["kind": "symbol", "name": "hammer.fill", "text": "H", "hue": 10, "source": "profile"]],
        ]]
        let icons = HarnessIconArtwork().lookup(for: HarnessIcons(harnessesReply: reply))
        let turns = Self.store()
        let tab = TabModel(Self.chatSnapshot("hammer", session: "mango"))
        func icon() -> TabIcon { TabItemMapping.shared.item(tab, fallbackTitle: "Chat", turns: turns, harnessIcons: icons).icon }
        #expect(icon() == .symbol("hammer.fill"), "no session icon: the harness's")

        turns.apply(session: "mango", state: nil, lastMessage: nil, muted: false, title: nil,
                    identity: AgentSessionIdentity(icon: .symbol("leaf.fill", monogram: "M", hue: 40, isOwn: false)), detail: nil)
        #expect(icon() == .symbol("leaf.fill"))
        #expect(SidebarMapping.agentMark(tab, harnessIcons: icons, turns: turns).icon == .symbol("leaf.fill"))

        turns.apply(session: "mango", state: nil, lastMessage: nil, muted: false, title: nil,
                    identity: AgentSessionIdentity(icon: .brand("gemini", isOwn: false)), detail: nil)
        #expect(icon() == .agentMark("gemini"))
        #expect(SidebarMapping.agentMark(tab, harnessIcons: icons, turns: turns).brand == "gemini")

        turns.apply(session: "mango", state: nil, lastMessage: nil, muted: false, title: nil,
                    identity: AgentSessionIdentity(icon: .emoji("🥭", isOwn: false)), detail: nil)
        guard case .image = icon() else { Issue.record("an emoji draws as an image: \(icon())"); return }
        #expect(icon() == icon(), "drawn once: the same image until the icon changes")
    }
}
