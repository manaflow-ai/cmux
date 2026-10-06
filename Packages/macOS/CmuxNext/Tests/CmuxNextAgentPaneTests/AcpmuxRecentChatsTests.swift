@testable import CmuxNextAgentPane
import Testing

/// The sidebar's Recents: acpmux's chats newest first, from `_acpmux/watch`
/// and its `_acpmux/session_changed` notifications, titled and marked as the
/// pane's session list did.
struct AcpmuxRecentChatsTests {
    static func session(_ id: String, updatedAt: Double, name: String? = nil, title: String? = nil, lastPrompt: String? = nil,
                        harness: String = "claude", status: String = "idle", unread: Bool = false, pending: Int = 0,
                        tags: [String: String] = [:]) -> [String: Any] {
        var summary: [String: Any] = ["sessionId": id, "updatedAt": updatedAt, "harness": harness, "status": status,
                                      "cwd": "/Users/me/repo", "unread": unread, "pendingPermissions": pending, "tags": tags]
        if let name { summary["name"] = name }
        if let title { summary["title"] = title }
        if let lastPrompt { summary["lastPrompt"] = lastPrompt }
        return summary
    }

    @Test func newestFirstAndCappedAtTheLimit() {
        var recents = AcpmuxRecentChats()
        recents.reset(["sessions": [
            Self.session("a", updatedAt: 10, name: "first"),
            Self.session("b", updatedAt: 30, name: "third"),
            Self.session("c", updatedAt: 20, name: "second"),
        ]])
        #expect(recents.newest(2).map(\.id) == ["b", "c"])
        #expect(recents.newest(10).map(\.id) == ["b", "c", "a"])
    }

    /// A generated name (`claude`, `claude-2`, `claude-fork`) gives way to the
    /// agent's title, then the first prompt; a chat with neither has no title
    /// (the sidebar draws "New chat"). A name the user gave wins.
    @Test func titlesFollowThePanesSessionList() {
        var recents = AcpmuxRecentChats()
        recents.reset(["sessions": [
            Self.session("named", updatedAt: 5, name: "deploy fix", title: "Ignored"),
            Self.session("titled", updatedAt: 4, name: "claude-2", title: "Fix the flaky tests"),
            Self.session("prompted", updatedAt: 3, name: "claude-fork", lastPrompt: "Why is CI red?"),
            Self.session("empty", updatedAt: 2, name: "claude"),
            Self.session("family", updatedAt: 1, name: "claude-sr", title: "Profiled", harness: "claude-sr"),
        ]])
        #expect(recents.newest(10).map(\.title) == ["deploy fix", "Fix the flaky tests", "Why is CI red?", nil, "Profiled"])
    }

    @Test func marksFollowThePanesSessionList() {
        var recents = AcpmuxRecentChats()
        recents.reset(["sessions": [
            Self.session("asks", updatedAt: 6, status: "running", pending: 1),
            Self.session("waits", updatedAt: 5, status: "waiting"),
            Self.session("runs", updatedAt: 4, status: "running"),
            Self.session("lost", updatedAt: 3, status: "disconnected"),
            Self.session("new", updatedAt: 2, unread: true),
            Self.session("quiet", updatedAt: 1),
        ]])
        #expect(recents.newest(10).map(\.mark) == [.input, .input, .running, .error, .unread, nil])
    }

    /// A change moves its chat to the top, a new session appears, a purged one
    /// leaves, and the Home Chief's sessions never show.
    @Test func changesUpdateTheList() {
        var recents = AcpmuxRecentChats()
        recents.reset(["sessions": [Self.session("a", updatedAt: 10, name: "a"), Self.session("b", updatedAt: 20, name: "b")]])
        recents.apply(changed: ["sessionId": "a", "kind": "turn_end", "session": Self.session("a", updatedAt: 30, name: "a")])
        #expect(recents.newest(10).map(\.id) == ["a", "b"])
        recents.apply(changed: ["sessionId": "c", "kind": "created", "session": Self.session("c", updatedAt: 40, name: "c")])
        recents.apply(changed: ["sessionId": "b", "kind": "purged", "session": Self.session("b", updatedAt: 50, name: "b")])
        let chief = [AcpmuxSessionCensus.chiefTagKey: "home"]
        recents.apply(changed: ["sessionId": "d", "kind": "created", "session": Self.session("d", updatedAt: 60, tags: chief)])
        #expect(recents.newest(10).map(\.id) == ["c", "a"])
    }

    @Test func aResetReplacesEverything() {
        var recents = AcpmuxRecentChats()
        recents.reset(["sessions": [Self.session("a", updatedAt: 1)]])
        recents.reset(["sessions": [Self.session("b", updatedAt: 1)]])
        #expect(recents.newest(10).map(\.id) == ["b"])
    }
}
