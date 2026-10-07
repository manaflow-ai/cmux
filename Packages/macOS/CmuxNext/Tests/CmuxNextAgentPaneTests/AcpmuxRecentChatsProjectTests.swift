@testable import CmuxNextAgentPane
import Testing

/// Leo (T3 Code ref, 2026-10-07): Recents filters by project, a chat's
/// folder. The filter applies before the limit, so a project's list fills up
/// with its own chats.
struct AcpmuxRecentChatsProjectTests {
    private static func session(_ id: String, updatedAt: Double, cwd: String) -> [String: Any] {
        var summary = AcpmuxRecentChatsTests.session(id, updatedAt: updatedAt, name: id)
        summary["cwd"] = cwd
        return summary
    }

    private static let recents: AcpmuxRecentChats = {
        var recents = AcpmuxRecentChats()
        recents.reset(["sessions": [
            session("a1", updatedAt: 1, cwd: "/p/alpha"),
            session("a2", updatedAt: 2, cwd: "/p/alpha"),
            session("a3", updatedAt: 3, cwd: "/p/alpha"),
            session("b1", updatedAt: 4, cwd: "/p/beta"),
            session("b2", updatedAt: 5, cwd: "/p/beta"),
            session("b3", updatedAt: 6, cwd: "/p/beta"),
            session("none", updatedAt: 0, cwd: ""),
        ]])
        return recents
    }()

    @Test func aProjectFiltersBeforeTheLimit() {
        #expect(Self.recents.newest(2, in: "/p/alpha").map(\.id) == ["a3", "a2"])
        #expect(Self.recents.newest(2, in: nil).map(\.id) == ["b3", "b2"], "nil is every project")
        #expect(Self.recents.newest(2, in: "/p/missing").isEmpty)
    }

    @Test func theProjectsAreTheChatsFoldersNewestFirst() {
        #expect(Self.recents.projects == ["/p/beta", "/p/alpha"], "a chat with no folder names no project")
    }
}
