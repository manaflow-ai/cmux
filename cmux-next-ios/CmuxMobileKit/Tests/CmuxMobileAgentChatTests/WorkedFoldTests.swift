import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A finished turn's work folds under "Worked for", its final reply shown, as the Mac transcript
/// folds a turn. Leo, 2026-11-17: "can we also just for the gui on ios collapse the agent messages
/// that come in by default? rn they're all showing ... rn they're just all expanded and it's kinda
/// undreadable :(".
@MainActor
@Suite struct WorkedFoldTests {
    static let at = Date(timeIntervalSince1970: 1_700_000_000)

    static func call(_ id: String, _ command: String) -> ACPToolCall {
        ACPToolCall(id: id, title: command, kind: .execute, status: .completed, rawInput: .object(["command": .string(command)]))
    }

    /// One turn: a note, two commands, a thought, another command, then the reply; `ended` nil leaves it running.
    static func rows(ended status: AgentTurn.Status? = .completed, steer: Bool = false) -> [ChatRow] {
        let store = AgentChatStore(source: PromptResendTests.Recorder())
        var events: [AgentSessionEvent] = [
            .userMessage(text: "fix the retry loop", promptId: "p1", turnId: "t1", attachments: [], at: at),
            .turnStarted(turnId: "t1", at: at),
            .update(.agentMessageChunk(text: "I'll read the helper first.", messageId: "m1")),
            .update(.toolCall(call("c1", "rg -n fetchWithRetry"))),
            .update(.toolCall(call("c2", "sed -n 1,80p src/fetch.ts"))),
            .update(.agentThoughtChunk(text: "The 404 path retries.")),
        ]
        if steer {
            events.append(.userMessage(text: "also check the timeout", promptId: "p2", turnId: "t1", attachments: [], at: at))
        }
        events += [
            .update(.toolCall(call("c3", "bun test fetch"))),
            .update(.agentMessageChunk(text: "Fixed: a 404 no longer retries.", messageId: "m2")),
        ]
        if let status {
            events.append(.turnResult(turnId: "t1", status: status, errorText: nil, at: at.addingTimeInterval(69)))
        }
        store.apply(.batch(events))
        return ChatTranscriptBuilder(diffs: ChatDiffCache()).build(turns: store.turns, pendingPermission: nil, askOpen: false,
                                                                   permissionBarHidden: false).flatMap(\.rows)
    }

    static func fold(_ rows: [ChatRow]) -> WorkedFold? {
        for row in rows { if case .worked(let fold) = row.kind { return fold } }
        return nil
    }

    static func shows(_ rows: [ChatRow], _ text: String) -> Bool {
        rows.contains { row in
            if case .block(_, let block) = row.kind, case .paragraph(let source) = block.kind { source.contains(text) } else { false }
        }
    }

    static func isWork(_ row: ChatRow) -> Bool {
        switch row.kind {
        case .tool, .toolGroup, .thought: true
        default: false
        }
    }

    @Test func aFinishedTurnShowsItsPromptOneWorkedForLineAndItsReply() throws {
        let rows = Self.rows()
        let fold = try #require(Self.fold(rows), "a finished turn's work folds under one line")
        #expect(fold.label == "Worked for 1m 9s")
        #expect(rows.filter { if case .worked = $0.kind { true } else { false } }.count == 1)
        #expect(!rows.contains(where: Self.isWork), "no tool, group or thought row shows outside the fold")
        #expect(!Self.shows(rows, "I'll read the helper first."), "the note between the work folds with it")
        #expect(Self.shows(rows, "Fixed: a 404 no longer retries."), "the final reply stays")
        // In order: the prompt, the line, the reply, then the actions.
        let worked = try #require(rows.firstIndex { $0.id == WorkedFold.rowID(turnID: "t1") })
        let reply = try #require(rows.firstIndex { Self.shows([$0], "Fixed") })
        let prompt = try #require(rows.firstIndex { $0.id == "u-t1" })
        #expect(prompt < worked && worked < reply)
        // Opened, it holds the work in the turn's order.
        #expect(Self.shows(fold.rows, "I'll read the helper first."))
        #expect(fold.rows.contains(where: Self.isWork))
        #expect(!Self.shows(fold.rows, "Fixed"), "the reply is never inside the fold")
    }

    @Test func aRunningTurnShowsItsWork() {
        let rows = Self.rows(ended: nil)
        #expect(Self.fold(rows) == nil)
        #expect(rows.contains(where: Self.isWork))
        #expect(Self.shows(rows, "I'll read the helper first."))
    }

    @Test func aFailedOrStoppedTurnSaysHowItEnded() {
        #expect(Self.fold(Self.rows(ended: .failed))?.label == "Failed after 1m 9s")
        #expect(Self.fold(Self.rows(ended: .cancelled))?.label == "You stopped after 1m 9s")
    }

    @Test func aSteeredMessageStaysWhereItWentIn() throws {
        let rows = Self.rows(steer: true)
        #expect(Self.fold(rows) != nil)
        let steer = try #require(rows.firstIndex { if case .steer = $0.kind { true } else { false } }, "the person's own words never fold")
        let worked = try #require(rows.firstIndex { $0.id == WorkedFold.rowID(turnID: "t1") })
        #expect(worked < steer)
    }

    @Test func durationsReadAsTheMacs() {
        #expect(WorkedFold.duration(0.4) == "0s")
        #expect(WorkedFold.duration(42) == "42s")
        #expect(WorkedFold.duration(76) == "1m 16s")
        #expect(WorkedFold.duration(3780) == "1h 3m")
        #expect(WorkedFold.label(status: .completed, seconds: nil) == "Worked")
    }
}

extension Array where Element == ChatRow {
    /// The rows with each "Worked for" line replaced by the rows it holds: what the transcript draws
    /// with every fold open.
    var unfolded: [ChatRow] {
        flatMap { row -> [ChatRow] in
            if case .worked(let fold) = row.kind { return fold.rows }
            return [row]
        }
    }
}
