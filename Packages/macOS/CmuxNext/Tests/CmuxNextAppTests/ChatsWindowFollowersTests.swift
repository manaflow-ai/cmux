@testable import CmuxNextAgentPane
import Foundation
import Testing

/// 2026-11-04 main-thread hang: the watchdog caught `ChatsFeed.apply` applying one drain of chat-index lines,
/// in `Window.answered()`. A drain carries up to 4,096 lines, and each window diff in it rebuilt the window's
/// rows, compared them, set them and ran every follower: a drain cost its diffs times the window's rows.
@MainActor @Suite struct ChatsWindowFollowersTests {
    private static func row(_ index: Int, title: String = "") -> AcpmuxChat {
        AcpmuxChat(json: ["key": "codex:\(index)", "sessionId": "\(index)", "harness": "codex",
                          "title": title.isEmpty ? "Chat \(index)" : title, "updatedMs": 1_000])!
    }

    private static func opened(_ id: String) throws -> (AcpmuxChatWindows, UInt64) {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        windows.open(AcpmuxChatWindows.Spec(window: id, limit: 500))
        return (windows, try #require(sent.last?["gen"] as? UInt64))
    }

    /// One drain of diffs to a window is one change of its rows: its followers run once, with the last rows.
    @Test func aDrainOfDiffsToOneWindowAppliesOnce() throws {
        let (windows, generation) = try Self.opened("test.drain")
        let window = windows.window("test.drain")
        let keys = (0..<500).map { "codex:\($0)" }
        windows.apply(.init(window: "test.drain", generation: generation, revision: 1, full: true, keys: keys,
                            rows: (0..<500).map { Self.row($0) }))
        final class Owner {}
        let owner = Owner()
        var calls: [[AcpmuxChat]] = []
        window.follow(owner) { calls.append($0) }
        // 4,000 diffs, each retitling one chat: what one full drain carries.
        let diffs = (0..<4_000).map { index in
            AcpmuxChatWindows.Update(window: "test.drain", generation: generation, revision: UInt64(index + 2), full: false,
                                     keys: keys, rows: [Self.row(index % 500, title: "Edit \(index)")])
        }
        windows.apply(contentsOf: diffs)
        #expect(calls.count == 1, "one drain, one call: \(calls.count)")
        #expect(window.revision == 4_001)
        #expect(window.rows.count == 500)
        #expect(window.rows[499].title == "Edit 3999" && window.rows[0].title == "Edit 3500", "the last edit of each chat wins")
        withExtendedLifetime(owner) {}
    }

    /// A drain that breaks the revision chain, or changes generation, is not merged across the break: the window
    /// asks again, as one diff at a time did.
    @Test func aGapInADrainAsksForTheWindowAgain() throws {
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        windows.open(AcpmuxChatWindows.Spec(window: "test.gap", limit: 10))
        let generation = try #require(sent.last?["gen"] as? UInt64)
        windows.apply(.init(window: "test.gap", generation: generation, revision: 1, full: true, keys: ["codex:1"], rows: [Self.row(1)]))
        let asked = sent.count
        windows.apply(contentsOf: [
            .init(window: "test.gap", generation: generation, revision: 2, full: false, keys: ["codex:1"], rows: [Self.row(1, title: "Two")]),
            .init(window: "test.gap", generation: generation, revision: 4, full: false, keys: ["codex:1"], rows: [Self.row(1, title: "Four")]),
        ])
        #expect(windows.window("test.gap").rows.first?.title == "Two", "the diff before the gap applies")
        #expect(sent.count == asked + 1, "the gap asks for the window again")
    }

    /// Followers that came and went cost nothing later: a window holds only its live ones after its next message.
    @Test func aBatchOfMessagesRunsOnlyLiveFollowers() throws {
        let (windows, generation) = try Self.opened("test.batch")
        let window = windows.window("test.batch")
        final class Owner {}
        for _ in 0..<10_000 { window.follow(Owner()) { _ in Issue.record("a follower whose owner is gone ran") } }
        let owner = Owner()
        var calls = 0
        window.follow(owner) { _ in calls += 1 }
        windows.apply(.init(window: "test.batch", generation: generation, revision: 1, full: true, keys: ["codex:1"], rows: [Self.row(1)]))
        for revision in 2...2_000 {
            windows.apply(.init(window: "test.batch", generation: generation, revision: UInt64(revision), full: false,
                                keys: ["codex:1"], rows: []))
        }
        #expect(calls == 2_000, "one call per message applied alone")
        #expect(window.followerCounts.live == 1 && window.followerCounts.held == 1, "\(window.followerCounts)")
        withExtendedLifetime(owner) {}
    }
}
