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

    @Test func anAgentChatShowsTheRowsItShowedBefore() {
        let ids = Self.shown(ChatTranscriptList(store: Self.chat(), surface: AgentChatSurface()))
        print("CMUX_CHAT_ROWS \(ids.joined(separator: ","))")
        #expect(ids == Self.golden, "\(ids)")
    }

    static let golden: [String] = []
}
#endif
