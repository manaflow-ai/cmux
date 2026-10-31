@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
import CmuxNextSidebar
import Foundation
import Testing

/// P-RUST item 2 (Lawrence's v2.2.9 hangs of 570 to 1,148 ms, 2026-10-30): with thousands of chats
/// in acpmux's index, one chat change must touch O(1) rows on the main thread. The hangs were the
/// whole-index mirror (deleted in #28090): its apply copied every chat (the sidebar history held the same
/// storage) and `SidebarChatHistoryFeed.chats`'s setter compared and freed every chat. Now acpmux
/// keeps the sidebar history's windows (`_acpmux/chats_window`): the main thread holds only their
/// visible rows and applies one row diff per change.
@MainActor @Suite struct ChatsWindowMainThreadTests {
    static let indexSize = 3000

    /// The requests the windows sent (method, params).
    @MainActor final class Sent {
        var methods: [String] = []
        var params: [[String: any Sendable]] = []

        func record(_ method: String, _ params: [String: any Sendable]) {
            methods.append(method)
            self.params.append(params)
        }
    }

    static func key(_ i: Int) -> String { "claude-code:s\(i)" }

    static func chat(_ i: Int, updatedMs: Int? = nil) -> AcpmuxChat {
        let ms = updatedMs ?? 1_800_000_000_000 - i * 1000
        return AcpmuxChat(id: key(i), sessionID: "s\(i)", harness: "claude-code", title: "chat \(i)", cwd: "/work/p\(i % 50)",
                          updatedAt: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// The history's Earlier window as acpmux answers it: the newest page and one more of `indexSize`.
    static func opened(send: @escaping @MainActor (String, [String: any Sendable]) -> Void = { _, _ in })
        -> (AcpmuxChatWindows, SidebarChatHistoryFeed.Inputs) {
        let windows = AcpmuxChatWindows()
        let inputs = SidebarChatHistoryFeed.Inputs(live: [], pinned: [], limit: SidebarChatHistory.pageSize, folded: false)
        windows.open(inputs.earlierSpec)
        windows.connected(send: send)
        let size = SidebarChatHistory.pageSize + 1
        windows.apply(.init(window: SidebarChatHistoryFeed.earlierWindow, revision: 1, full: true, keys: (0..<size).map(key),
                            rows: (0..<size).map { chat($0) }))
        return (windows, inputs)
    }

    /// One change to one chat of 3,000 (the oldest moves to the top): acpmux sends its one row,
    /// and the main thread touches that row and the window's keys, never the index.
    @Test func oneChatChangeAmongThreeThousandTouchesOneRowOnMain() {
        let (windows, inputs) = Self.opened()
        let earlier = windows.window(SidebarChatHistoryFeed.earlierWindow)
        let before = earlier.rows
        let moved = Self.indexSize - 1
        windows.apply(.init(window: SidebarChatHistoryFeed.earlierWindow, revision: 2, full: false,
                            keys: [Self.key(moved)] + before.dropLast().map(\.id),
                            rows: [Self.chat(moved, updatedMs: 1_900_000_000_000)]))
        // The rows the main thread holds for the sidebar history: its visible window at most.
        let held = earlier.rows.count
        #expect(held <= SidebarChatHistory.pageSize + 1, "the main thread holds \(held) chats for a window of \(SidebarChatHistory.pageSize)")
        #expect(windows.lastTouchedRows == 1, "one changed chat is one row")
        #expect(earlier.rows.map(\.id) == [Self.key(moved)] + before.dropLast().map(\.id))
        #expect(Array(earlier.rows.dropFirst()) == Array(before.dropLast()), "the other rows are the snapshots it had")
        let state = SidebarChatHistoryFeed.state(earlier: earlier.rows, pinned: [], inputs: inputs)
        #expect(state.earlier.count == SidebarChatHistory.pageSize)
        #expect(state.earlier.first?.id == Self.key(moved))
        #expect(state.hasMore)
    }

    /// A diff that does not follow the last revision, or names a row the window never got, is not
    /// applied: the window is asked for again, once until its full rows come.
    @Test func aMissedDiffAsksForTheWindowAgainOnce() {
        let sent = Sent()
        let (windows, _) = Self.opened(send: sent.record)
        #expect(sent.methods == ["_acpmux/chats_window"])
        sent.methods = []
        let earlier = windows.window(SidebarChatHistoryFeed.earlierWindow)
        let before = earlier.rows
        windows.apply(.init(window: SidebarChatHistoryFeed.earlierWindow, revision: 3, full: false, keys: before.map(\.id),
                            rows: []))
        #expect(sent.methods == ["_acpmux/chats_window"])
        #expect(earlier.rows == before)
        windows.apply(.init(window: SidebarChatHistoryFeed.earlierWindow, revision: 4, full: false, keys: before.map(\.id),
                            rows: []))
        #expect(sent.methods == ["_acpmux/chats_window"], "one ask until the full rows come")
        windows.apply(.init(window: SidebarChatHistoryFeed.earlierWindow, revision: 5, full: true, keys: [Self.key(7)],
                            rows: [Self.chat(7)]))
        #expect(earlier.rows.map(\.id) == [Self.key(7)])
        windows.apply(.init(window: SidebarChatHistoryFeed.earlierWindow, revision: 6, full: false, keys: [Self.key(8)],
                            rows: []))
        #expect(sent.methods == ["_acpmux/chats_window", "_acpmux/chats_window"], "a row it never got: asked again")
        #expect(earlier.rows.map(\.id) == [Self.key(7)])
    }

    /// The same spec twice sends one request; a reconnect asks for every open window again.
    @Test func anUnchangedSpecSendsNothingAndAReconnectAsksAgain() {
        let windows = AcpmuxChatWindows()
        let sent = Sent()
        windows.connected(send: sent.record)
        let inputs = SidebarChatHistoryFeed.Inputs(live: ["claude-code:s1"], pinned: ["claude-code:s2"], limit: 20, folded: false)
        windows.open(inputs.earlierSpec)
        windows.open(inputs.earlierSpec)
        #expect(sent.params.count == 1)
        #expect(sent.params.first?["exclude"] as? [String] == ["claude-code:s1", "claude-code:s2"])
        #expect(sent.params.first?["limit"] as? Int == 21)
        windows.disconnected()
        windows.connected(send: sent.record)
        #expect(sent.params.count == 2)
    }

    /// Review F1 (#28055): each spec the client sends names its generation (`gen`), and a message
    /// for an older spec of the window (acpmux answered the requests out of order) is never applied,
    /// even a full one: the window keeps waiting for its current spec's rows.
    @Test func aMessageForAnOlderSpecOfTheWindowIsNotApplied() {
        let windows = AcpmuxChatWindows()
        let sent = Sent()
        windows.connected(send: sent.record)
        windows.open(.init(window: "w", limit: 3))
        windows.open(.init(window: "w", limit: 5))
        let gens = sent.params.map { ($0["gen"] as? UInt64) ?? 0 }
        #expect(gens.count == 2 && gens[1] > gens[0], "each spec names a newer generation: \(gens)")
        let older: [String: Any] = ["window": "w", "gen": NSNumber(value: gens.first ?? 0), "revision": 1, "full": true,
                                    "keys": [Self.key(0)], "rows": [["key": Self.key(0), "sessionId": "s0", "harness": "claude-code",
                                                                     "updatedMs": 1_800_000_000_000]]]
        if let update = AcpmuxChatWindows.Update(params: older) { windows.apply(update) }
        #expect(windows.window("w").rows.isEmpty, "the older spec's rows were applied")
    }

    /// Review F3 (#28055): acpmux refused a window request (busy): the window is not left waiting
    /// for a full message that never comes; the next sign that the daemon serves asks again.
    @Test func aRefusedRequestIsAskedAgainWhenTheDaemonServes() {
        let windows = AcpmuxChatWindows()
        let sent = Sent()
        windows.connected(send: sent.record)
        windows.open(.init(window: "w", limit: 3))
        #expect(sent.methods == ["_acpmux/chats_window"])
        windows.requestFailed("w")
        windows.retryFailed()
        #expect(sent.methods == ["_acpmux/chats_window", "_acpmux/chats_window"], "a refused window is asked again")
        windows.retryFailed()
        #expect(sent.methods.count == 2, "once per refusal")
    }
}
