@testable import CmuxNextAgentPane
import Foundation
import Testing

/// A New Tab page lists the recent chats on its first frame (Leo 2026-10-19: "there's still a split
/// second flicker upon opening up new workspaces wrt the semi dynamic content on the recent chats
/// and the recent project"). A local page posts its newest chats (`newTab.warm`); the host keeps
/// them and every opening's context carries them (`AgentPaneNewTab.warm`).
@MainActor
@Suite(.serialized)
struct NewTabWarmSnapshotTests {
    private static let warm = #"{"sessions":[{"sessionId":"s1","displayTitle":"Fix the build","updatedAt":1}]}"#

    @Test func thePageRequestDecodesAndAnOversizedOneIsRefused() throws {
        let request = AgentPaneRequest(body: ["method": "newTab.warm", "params": ["warm": ["sessions": []]]])
        #expect(request == .newTabWarm(#"{"sessions":[]}"#))
        let big = String(repeating: "x", count: AgentPaneNewTab.maximumWarmBytes)
        #expect(AgentPaneRequest(body: ["method": "newTab.warm", "params": ["warm": ["sessions": [big]]]])
            == .unsupported("newTab.warm"))
        #expect(AgentPaneRequest(body: ["method": "newTab.warm"]) == .unsupported("newTab.warm"))
        #expect(AgentPageOps.all.contains(AgentPageOps.namespace + "newTab.warm"))
    }

    @Test func aLocalPageWarmsTheNextContextAndStaysUntouched() async throws {
        AgentPaneNewTab.warmed = nil
        defer { AgentPaneNewTab.warmed = nil }
        let model = AgentPaneModel(host: NoHost())
        #expect(await model.respond(to: .newTabWarm(Self.warm))["ok"] as? Bool == true)
        // A prewarmed spare that posts its list is still recycled into the pool.
        #expect(!model.userTouched)
        let page = AgentPaneNewTab(kind: .agent).warmedOnThisMac()
        #expect(page.warm == Self.warm)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        #expect(json["warm"] as? String == Self.warm)
        // A page on another machine lists that machine's chats, not this Mac's.
        #expect(AgentPaneNewTab(kind: .agent).warmedOnThisMac(false).warm == nil)
        // Nor the chats this Mac's pages share (webviews newtab/chatStore.ts) before its handshake.
        #expect(AgentPaneNewTab(kind: .agent).warmedOnThisMac(false).privateChatLists == true)
    }

    @Test func anotherMachinesPageDoesNotWarmThisMacsPages() async {
        AgentPaneNewTab.warmed = nil
        defer { AgentPaneNewTab.warmed = nil }
        let remote = AgentPaneModel(host: NoHost())
        remote.remoteChat = true
        _ = await remote.respond(to: .newTabWarm(Self.warm))
        #expect(AgentPaneNewTab.warmed == nil)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
