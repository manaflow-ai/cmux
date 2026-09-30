import Foundation
import Testing
@testable import CmuxAcpmux

struct TranscriptReducerTests {
    private func summaries(_ rows: [TranscriptRow]) -> [String] {
        rows.map { row in
            switch row.content {
            case .user(let message): return "user:\(message.text)"
            case .assistant(let text, let streaming): return "assistant:\(text)\(streaming ? "…" : "")"
            case .activity(let group): return "activity:\(group.items.count)/\(group.toolCount)"
            case .plan(let entries): return "plan:\(entries.count)"
            case .permission(let card): return "permission:\(card.isPending ? "pending" : "resolved")"
            case .turnSummary(let summary): return "turn:\(summary.status):\(summary.toolCount)"
            case .typing: return "typing"
            case .notice(let text): return "notice:\(text)"
            }
        }
    }

    @Test func fakeAgentAttachFoldsIntoTurns() throws {
        let attach = try FixtureLoader().fakeAttach()
        var reducer = TranscriptReducer()
        reducer.apply(attach.events)
        #expect(summaries(reducer.rows) == [
            "user:hello there",
            "activity:1/0",
            "assistant:echo: hello there",
            "turn:completed:0",
            "user:ask: may I?",
            "permission:resolved",
            "assistant:chose yes",
            "turn:completed:0",
            "user:slow",
            "assistant:tick0 tick1 ",
            "turn:cancelled:0",
        ])
        #expect(reducer.isTurnOpen == false)
        #expect(reducer.lastSeq == 42)
    }

    @Test func liveNotificationsMatchBackfill() throws {
        let loader = FixtureLoader()
        let attach = try loader.fakeAttach()
        var backfill = TranscriptReducer()
        backfill.apply(attach.events)

        var live = TranscriptReducer()
        // The session was created before the notifications started; seed the first records.
        live.apply(attach.events.filter { $0.seq <= 5 })
        for note in try loader.fakeLiveNotifications() {
            switch note.method {
            case "session/update":
                if let record = AcpmuxEventRecord(liveSessionUpdate: note.params) { live.apply(record) }
            case "_acpmux/event":
                if let record = AcpmuxEventRecord(liveMuxEvent: note.params) { live.apply(record) }
            default:
                continue
            }
        }
        #expect(live.rows.map(\.id) == backfill.rows.map(\.id))
        #expect(summaries(live.rows) == summaries(backfill.rows))
    }

    @Test func typingIndicatorShowsUntilFirstOutput() throws {
        let events = try FixtureLoader().fakeAttach().events
        var reducer = TranscriptReducer()
        reducer.apply(events.filter { $0.seq <= 10 })
        #expect(summaries(reducer.rows) == ["user:hello there", "typing"])
        #expect(reducer.isTurnOpen)
        reducer.apply(events.filter { $0.seq <= 12 })
        #expect(summaries(reducer.rows) == ["user:hello there", "activity:1/0", "assistant:echo: hello there…"])
    }

    @Test func streamingChunksAppendToOneRowAndBumpVersion() throws {
        let events = try FixtureLoader().fakeAttach().events
        var reducer = TranscriptReducer()
        reducer.apply(events.filter { $0.seq <= 36 })
        let first = try #require(reducer.rows.last)
        reducer.apply(events.filter { $0.seq == 37 })
        let second = try #require(reducer.rows.last)
        #expect(first.id == second.id)
        #expect(second.version > first.version)
        #expect(second.content == .assistant(text: "tick0 tick1 ", isStreaming: true))
    }

    @Test func pendingLocalEchoIsReplacedByDaemonRecord() throws {
        var reducer = TranscriptReducer()
        reducer.addPendingUserMessage(promptId: "p1", text: "hi", at: 1)
        #expect(summaries(reducer.rows) == ["user:hi", "typing"])
        guard case .user(let pending) = reducer.rows[0].content else { Issue.record("not a user row"); return }
        #expect(pending.isPending)
        let record = AcpmuxEventRecord(
            sessionId: "s", seq: 1, at: 2, dir: "mux", kind: "user_message",
            msg: .object(["text": .string("hi"), "promptId": .string("p1")])
        )
        reducer.apply(record)
        #expect(reducer.rows.map(\.id) == ["user-p1", "typing"])
        guard case .user(let confirmed) = reducer.rows[0].content else { Issue.record("not a user row"); return }
        #expect(!confirmed.isPending)
    }

    @Test func localEchoReconcilesByTextWhenDaemonOmitsPromptId() {
        var reducer = TranscriptReducer()
        reducer.addPendingUserMessage(promptId: "p1", text: "hi", at: 1)
        reducer.apply(AcpmuxEventRecord(
            sessionId: "s", seq: 1, at: 2, dir: "mux", kind: "user_message",
            msg: .object(["text": .string("hi")])
        ))
        #expect(reducer.rows.map(\.id) == ["user-p1", "typing"])
        guard case .user(let confirmed) = reducer.rows[0].content else { Issue.record("not a user row"); return }
        #expect(!confirmed.isPending)
    }

    @Test func codexSessionGroupsThoughtsAndToolsAndSkipsNoise() throws {
        let records = try FixtureLoader().codexSessionRecords()
        var reducer = TranscriptReducer()
        reducer.apply(records)
        let rows = reducer.rows
        let userRows = rows.filter { if case .user = $0.content { return true } else { return false } }
        #expect(userRows.count == 2)
        let toolCount = rows.reduce(0) { total, row in
            if case .activity(let group) = row.content { return total + group.toolCount }
            return total
        }
        // Four distinct tool call ids appear in the log.
        #expect(toolCount == 4)
        #expect(!rows.contains { $0.content == .typing })
        #expect(Set(rows.map(\.id)).count == rows.count)
        let failedTool = rows.compactMap { row -> TranscriptToolCall? in
            guard case .activity(let group) = row.content else { return nil }
            return group.items.compactMap { item -> TranscriptToolCall? in
                if case .tool(let call) = item, call.status == "failed" { return call }
                return nil
            }.first
        }.first
        #expect(failedTool?.output?.contains("No such file") == true)
    }

    @Test func prependRebuildsWithOlderHistory() throws {
        let records = try FixtureLoader().codexSessionRecords()
        var full = TranscriptReducer()
        full.apply(records)

        var paged = TranscriptReducer()
        paged.apply(records.filter { $0.seq > 100 })
        paged.prepend(records.filter { $0.seq <= 100 })
        #expect(paged.rows.map(\.id) == full.rows.map(\.id))
        #expect(paged.firstSeq == 1)
    }

    @Test func redeliveredMessageReplacesAbandonedPartial() {
        // Captured shape from a codex turn whose stream dropped: the partial message and
        // the resent message carry different messageIds. Only the full answer remains.
        func chunk(_ seq: Int, _ text: String, _ messageID: String) -> AcpmuxEventRecord {
            AcpmuxEventRecord(
                sessionId: "s", seq: seq, at: Int64(seq), dir: "in", kind: "agent_message_chunk",
                msg: .object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object(["update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string(text)]),
                    "messageId": .string(messageID),
                ])])])
            )
        }
        var reducer = TranscriptReducer()
        reducer.apply([
            AcpmuxEventRecord(sessionId: "s", seq: 1, at: 1, dir: "mux", kind: "user_message", msg: .object(["text": .string("ls")])),
            chunk(2, "The directory contains", "m1"),
            chunk(3, " a", "m1"),
            chunk(4, "The directory contains", "m2"),
            chunk(5, " one file.", "m2"),
        ])
        #expect(summaries(reducer.rows) == [
            "user:ls",
            "assistant:The directory contains one file.…",
        ])
    }

    @Test func messageSupersededDropsTheOldMessageWithoutTheFallback() {
        func chunk(_ seq: Int, _ text: String, _ messageID: String) -> AcpmuxEventRecord {
            AcpmuxEventRecord(
                sessionId: "s", seq: seq, at: Int64(seq), dir: "in", kind: "agent_message_chunk",
                msg: .object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object(["update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string(text)]),
                    "messageId": .string(messageID),
                ])])])
            )
        }
        var reducer = TranscriptReducer()
        reducer.usesRedeliveryFallback = false
        reducer.apply([
            AcpmuxEventRecord(sessionId: "s", seq: 1, at: 1, dir: "mux", kind: "user_message", msg: .object(["text": .string("ls")])),
            chunk(2, "Partial answ", "m1"),
            AcpmuxEventRecord(sessionId: "s", seq: 3, at: 3, dir: "mux", kind: "message_superseded", msg: .object([
                "oldMessageId": .string("m1"), "newMessageId": .string("m2"), "reason": .string("harness_retry"),
            ])),
            chunk(4, "Full answer.", "m2"),
            chunk(5, " late", "m1"),
        ])
        #expect(summaries(reducer.rows) == ["user:ls", "assistant:Full answer.…"])
    }

    @Test func failedTurnHidesExactlyTheErrorChunks() {
        var reducer = TranscriptReducer()
        func chunk(_ seq: Int, _ text: String) -> AcpmuxEventRecord {
            AcpmuxEventRecord(
                sessionId: "s", seq: seq, at: Int64(seq), dir: "in", kind: "agent_message_chunk",
                msg: .object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object(["update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string(text)]),
                    "messageId": .string("m\(seq)"),
                ])])])
            )
        }
        reducer.apply([
            AcpmuxEventRecord(sessionId: "s", seq: 1, at: 1, dir: "mux", kind: "user_message", msg: .object(["text": .string("hi")])),
            chunk(2, "Real prose."),
            chunk(3, "Quota exceeded"),
            AcpmuxEventRecord(sessionId: "s", seq: 4, at: 4, dir: "mux", kind: "turn_result", msg: .object([
                "status": .string("failed"), "errorText": .string("Quota exceeded"), "errorChunkSeqs": .array([.number(3)]),
            ])),
        ])
        #expect(summaries(reducer.rows) == ["user:hi", "assistant:Real prose.", "turn:failed:0"])
    }

    @Test func lastTurnShowsAFailureMissingFromTheLoadedHistory() {
        var reducer = TranscriptReducer()
        reducer.applyLastTurn(.object([
            "turnId": .string("t1"), "status": .string("failed"), "errorText": .string("boom"), "endedAt": .number(5),
        ]))
        #expect(summaries(reducer.rows) == ["turn:failed:0"])
    }

    @Test func distinctConsecutiveMessagesStaySeparate() {
        func chunk(_ seq: Int, _ text: String, _ messageID: String) -> AcpmuxEventRecord {
            AcpmuxEventRecord(
                sessionId: "s", seq: seq, at: Int64(seq), dir: "in", kind: "agent_message_chunk",
                msg: .object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object(["update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string(text)]),
                    "messageId": .string(messageID),
                ])])])
            )
        }
        var reducer = TranscriptReducer()
        reducer.apply([
            AcpmuxEventRecord(sessionId: "s", seq: 1, at: 1, dir: "mux", kind: "user_message", msg: .object(["text": .string("go")])),
            chunk(2, "Checking now.", "m1"),
            chunk(3, "Done: all good.", "m2"),
        ])
        #expect(summaries(reducer.rows) == ["user:go", "assistant:Checking now.…", "assistant:Done: all good.…"])
    }

    @Test func failedTurnMovesStreamedErrorTextOutOfBubbles() {
        var reducer = TranscriptReducer()
        let limit = "You've hit your weekly limit · resets Oct 2 at 4am (America/Los_Angeles)"
        reducer.apply([
            AcpmuxEventRecord(sessionId: "s", seq: 1, at: 1, dir: "mux", kind: "user_message", msg: .object(["text": .string("hi")])),
            AcpmuxEventRecord(
                sessionId: "s", seq: 2, at: 2, dir: "in", kind: "agent_message_chunk",
                msg: .object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object(["update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string(limit)]),
                ])])])
            ),
            AcpmuxEventRecord(sessionId: "s", seq: 3, at: 3, dir: "mux", kind: "turn_result", msg: .object([
                "status": .string("failed"), "error": .string("Internal error: " + limit), "turnSeq": .number(1),
            ])),
        ])
        #expect(summaries(reducer.rows) == ["user:hi", "turn:failed:0"])
    }

    @Test func failedLocalMessageCanBeTakenForRetry() {
        var reducer = TranscriptReducer()
        reducer.addPendingUserMessage(promptId: "p", text: "hello", at: 1)
        reducer.markPendingUserMessageFailed(promptId: "p")
        #expect(reducer.takeFailedMessage(rowID: "user-p") == "hello")
        #expect(reducer.rows.isEmpty)
    }

    @Test func queueTracksQueuedAndDequeuedPrompts() {
        var reducer = TranscriptReducer()
        reducer.apply(AcpmuxEventRecord(
            sessionId: "s", seq: 1, at: 1, dir: "mux", kind: "queued",
            msg: .object(["promptId": .string("q1"), "text": .string("later"), "delivery": .string("turn")])
        ))
        #expect(reducer.queue.map(\.promptId) == ["q1"])
        reducer.apply(AcpmuxEventRecord(
            sessionId: "s", seq: 2, at: 2, dir: "mux", kind: "user_message",
            msg: .object(["promptId": .string("q1"), "text": .string("later"), "fromQueue": .bool(true)])
        ))
        #expect(reducer.queue.isEmpty)
    }
}
