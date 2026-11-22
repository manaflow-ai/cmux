#if os(iOS)
@testable import CmuxMobileAgentChat
import Foundation
import Testing
import UIKit

/// An agent chat's transcript list shows the rows it showed before the source seam (#47189):
/// the same row ids, read from the list at the base (`golden`). This file compiles at the base.
@MainActor
@Suite struct ChatRowsGoldenTests {
    static let at = SmoothChatTests.at

    /// Three finished turns (one with an edit), a failed one, then a running turn.
    static func chat() -> AgentChatStore {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        var events = SmoothChatTests.turn(0) + SmoothChatTests.turn(1, edit: true) + SmoothChatTests.turn(2)
        events += [
            .userMessage(text: "try the fix", promptId: "p3", turnId: "t3", attachments: [], at: at),
            .turnStarted(turnId: "t3", at: at),
            .update(.agentThoughtChunk(text: "Checking the retry path.")),
            .update(.toolCall(ACPToolCall(id: "c3a", title: "bun test", kind: .execute, status: .completed,
                                          rawInput: .object(["command": .string("bun test")])))),
            .turnResult(turnId: "t3", status: .failed, errorText: "exit 1", at: at),
            .userMessage(text: "again", promptId: "p4", turnId: "t4", attachments: [], at: at),
            .turnStarted(turnId: "t4", at: at),
            .update(.toolCall(ACPToolCall(id: "c4a", title: "Read a.swift", kind: .read, status: .completed))),
            .update(.agentMessageChunk(text: "Still running", messageId: "m4")),
        ]
        store.apply(.batch(events))
        return store
    }

    static func shown(_ list: ChatTranscriptList) -> [String] {
        list.collectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        list.boundsMayHaveChanged()
        list.collectionView.layoutIfNeeded()
        return list.layout.items.map(\.id)
    }

    /// FNV-1a: stable across runs (Swift's `hashValue` is seeded per process).
    static func fnv(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// Each row the list shows: its id, its kind and a hash of everything it draws (its text,
    /// a tool's name and state, a fold's state, its gap). Wall-clock times are left out: the store
    /// stamps a tool call's start and end with the time it applied the record, which differs per
    /// run (seen: the same build hashed a fold and a tool row differently in two runs).
    static func rows(_ list: ChatTranscriptList) -> String {
        shown(list).map { id in
            guard let row = list.row(id) else { return "\(id)|missing" }
            return "\(id)|\(row.hostedReuseKey)|\(fnv(withoutClockTimes(String(reflecting: row.kind)) + " gap \(row.gap)"))"
        }.joined(separator: ";")
    }

    /// The description with every date (`2026-11-22 10:13:51 +0000`) replaced by the fixture's
    /// time when it is the fixture's, else by "now".
    static func withoutClockTimes(_ text: String) -> String {
        let fixture = String(describing: at)
        let pattern = #/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \+\d{4}/#
        return text.replacing(pattern) { match in String(match.output) == fixture ? "fixture" : "now" }
    }

    /// The chat as it opens: finished, edited, failed and running turns.
    @Test func anAgentChatShowsTheRowsItShowedBefore() {
        let shown = Self.rows(ChatTranscriptList(store: Self.chat(), surface: AgentChatSurface()))
        #expect(shown == Self.golden["open"], "CMUX_CHAT_ROWS open=\(shown)")
    }

    /// A chat opened on its newest page: older history waits above (the session line says so).
    @Test func aChatWithOlderHistoryShowsTheRowsItShowedBefore() {
        let store = Self.chat()
        store.apply(.earlierHistory(true))
        let shown = Self.rows(ChatTranscriptList(store: store, surface: AgentChatSurface()))
        #expect(shown == Self.golden["older"], "CMUX_CHAT_ROWS older=\(shown)")
    }

    /// A chat past its window, the reader resting on its end: the oldest turns go to disk.
    @Test func aWindowedChatShowsTheRowsItShowedBefore() {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch((0..<(AgentChatStore.windowTrigger + 6)).flatMap { SmoothChatTests.turn($0) }))
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface())
        _ = Self.shown(list)
        list.spillIfResting()
        list.reload()
        let shown = Self.rows(list)
        #expect(shown == Self.golden["window"], "CMUX_CHAT_ROWS window=\(store.turns.count) turns \(shown)")
    }

    /// Read from the list at the base (the pre-seam head), by these same tests.
    static let golden: [String: String] = [:]
}
#endif
