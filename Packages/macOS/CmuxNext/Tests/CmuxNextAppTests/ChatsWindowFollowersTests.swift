@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
import Foundation
import Testing

/// 2026-11-04 main-thread hang: the watchdog caught `Window.answered()` sweeping the palette window's
/// followers on every message of a batch. Every palette query answered at once (the same query again, or
/// no connection) kept its follower for good, so each later message ran every such query ever made.
@MainActor @Suite struct ChatsWindowFollowersTests {
    private static func row(_ index: Int) -> AcpmuxChat {
        AcpmuxChat(json: ["key": "codex:\(index)", "sessionId": "\(index)", "harness": "codex", "title": "Chat \(index)",
                          "updatedMs": 1_000])!
    }

    @Test(.timeLimit(.minutes(1))) func queriesAnsweredAtOnceLeaveNoFollower() async throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        let first = AgentChatsPalettePage.answers("", windows: windows, open: { _ in })
        let generation = try #require(sent.last?["gen"] as? UInt64)
        windows.apply(.init(window: AgentChatsPalettePage.window, generation: generation, revision: 1, full: true,
                            keys: ["codex:1"], rows: [Self.row(1)]))
        for await _ in first {}
        // The same query again: the window already answered its spec, so each stream ends before it returns.
        for _ in 0..<500 {
            for await _ in AgentChatsPalettePage.answers("", windows: windows, open: { _ in }) {}
        }
        // No connection: each query ends at once with no rows.
        windows.disconnected()
        for _ in 0..<500 {
            for await _ in AgentChatsPalettePage.answers("zebra", windows: windows, open: { _ in }) {}
        }
        let counts = windows.window(AgentChatsPalettePage.window).followerCounts
        #expect(counts.live == 0, "an ended query holds no follower: \(counts)")
        #expect(counts.held <= 32, "dead followers are dropped as they come: \(counts)")
    }

    /// A batch of messages costs what the window's live readers cost: a window that had thousands of readers come
    /// and go holds only the live ones after its next message.
    @Test func aBatchOfMessagesRunsOnlyLiveFollowers() throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        let spec = AcpmuxChatWindows.Spec(window: "test.batch", limit: 10)
        windows.open(spec)
        let generation = try #require(sent.last?["gen"] as? UInt64)
        let window = windows.window(spec.window)
        final class Owner {}
        for _ in 0..<10_000 { window.follow(Owner()) { _ in Issue.record("a follower whose owner is gone ran") } }
        let owner = Owner()
        var calls = 0
        window.follow(owner) { _ in calls += 1 }
        #expect(window.followerCounts.held <= 2 * 16 + 1, "adding drops the gone followers: \(window.followerCounts)")
        windows.apply(.init(window: spec.window, generation: generation, revision: 1, full: true, keys: ["codex:1"], rows: [Self.row(1)]))
        for revision in 2...5_000 {
            windows.apply(.init(window: spec.window, generation: generation, revision: UInt64(revision), full: false,
                                keys: ["codex:1"], rows: []))
        }
        #expect(calls == 5_000, "one call per message")
        #expect(window.followerCounts.live == 1 && window.followerCounts.held == 1, "\(window.followerCounts)")
        withExtendedLifetime(owner) {}
    }
}
