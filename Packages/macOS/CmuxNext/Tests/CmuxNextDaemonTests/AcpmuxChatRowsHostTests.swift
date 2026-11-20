import Foundation
import Testing
@testable import CmuxNextAgentList

/// One step of a recorded chat stream: the client calls, then the daemon bytes fed, then the
/// changes the core gives.
private struct ChatStep {
    var calls: [[String: Any]] = []
    var range: Range<Int> = 0..<0
    var changes = 0
}

private func chatSteps(_ name: String) throws -> [ChatStep] {
    let data = try Data(contentsOf: agentChatFixtures.appendingPathComponent(name))
    var steps: [ChatStep] = []
    for line in data.split(separator: 0x0A) {
        if line.first == UInt8(ascii: "\"") {
            try #require(!steps.isEmpty)
            // The host acts on a `fallback` change itself and never hands it to the page.
            let change = try JSONSerialization.jsonObject(with: Data(line), options: .fragmentsAllowed) as? String
            if AcpmuxChatRowsBatch.kind(of: Data((change ?? "").utf8)) != "fallback" { steps[steps.count - 1].changes += 1 }
            continue
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        if object["step"] != nil {
            steps.append(ChatStep())
        } else if object["call"] is String {
            steps[steps.count - 1].calls.append(object)
        } else if let feed = object["feed"] as? [Int], feed.count == 2 {
            steps[steps.count - 1].range = feed[0]..<feed[1]
        }
    }
    return steps
}

/// Runs a recorded stream through the host as the page would (open, page, blob) with the daemon's
/// bytes fed in `chunk`-byte reads, and returns what the stand-in receiver got.
private func replay(_ name: String, chunk: Int) async throws -> FedChatRowsHost {
    let fed = FedChatRowsHost()
    let bytes = try Data(contentsOf: agentChatFixtures.appendingPathComponent(name.replacingOccurrences(of: ".jsonl", with: ".bytes")))
    var expected = 0
    for step in try chatSteps(name) {
        for call in step.calls {
            let request = (call["request"] as? [String: Any]) ?? [:]
            let body = ChatWire.request(request)
            let sid = request["sid"] as? String ?? ""
            switch call["call"] as? String {
            case "subscribe_chat":
                #expect(await fed.host.open(sid: sid, request: body) == .success(sid))
            case "chat_page":
                #expect(await fed.host.page(sid: sid, request: body) == .success(()))
            case "chat_blob":
                let id = request["id"] as? String ?? ""
                #expect(await fed.host.blob(sid: sid, id: id, request: body) == .success(id))
            case "connected":
                // The host's first open connects; a later one is the recorded resume.
                if step.calls.contains(where: { $0["call"] as? String == "disconnected" }) { _ = fed.client?.connected() }
            case "disconnected":
                _ = fed.client?.disconnected()
            default:
                Issue.record("unknown recorded call \(call)")
            }
        }
        while fed.client?.takeSend() != nil {}
        try await fed.feed(Data(bytes[step.range]), chunk: chunk)
        expected += step.changes
        let target = expected
        #expect(await eventually { fed.receiver.changes.count >= target })
    }
    return fed
}

extension Result where Success == Void, Failure == AcpmuxChatRowsHost.Refusal {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.success, .success): true
        case (.failure(let a), .failure(let b)): a == b
        default: false
        }
    }
}

@Suite("AcpmuxChatRowsHostTests", .serialized)
struct AcpmuxChatRowsHostTests {
    @Test("the recorded daemon bytes give the recorded changes byte for byte", arguments: [Int.max, 7, 1])
    func recordedStream(chunk: Int) async throws {
        let fed = try await replay("chat.jsonl", chunk: chunk)
        let expected = try recordedChatChanges("chat.jsonl")
        #expect(fed.receiver.changes == expected)
        #expect(fed.receiver.failures == 0)
        // Batches are numbered from 1, one call each.
        #expect(fed.receiver.batches.map(\.batch) == Array(1...fed.receiver.batches.count))
        let counters = await fed.host.snapshotForTesting().counters
        #expect(counters.bridgeCalls == fed.receiver.batches.count)
        #expect(counters.timersArmed == 0)
    }

    @Test("the v1 answer: each open sid gets its chatError, the connection closes, the next open upgrades again")
    func v1Answer() async throws {
        let fed = try await replay("fallback.jsonl", chunk: 7)
        let recorded = try recordedChatChanges("fallback.jsonl")
        // The fallback change is the host's to act on; the page gets the two sub errors.
        #expect(fed.receiver.changes == recorded.filter { AcpmuxChatRowsBatch.kind(of: $0) != "fallback" })
        #expect(fed.receiver.changes.count == 2)
        #expect(await eventually { await fed.host.snapshotForTesting().driver == nil })
        let after = await fed.host.snapshotForTesting()
        #expect(after.client == nil && after.sids.isEmpty)
        #expect(await fed.host.open(sid: "rows.3", request: ChatWire.request(["sid": "rows.3", "chat": "chat-a"])) == .success("rows.3"))
        #expect(fed.clientCount == 2, "a new handle")
        let upgrade = try #require(fed.client?.takeSend())
        #expect(String(decoding: upgrade, as: UTF8.self).contains("\"method\":\"_acpmux/v2\""), "the new handle upgrades again")
    }

    @Test("no batch is over 64 KiB unless it is one change: a 200 KiB window and a run of small ops")
    func batchBound() async throws {
        let fed = FedChatRowsHost()
        #expect(await fed.host.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"))
        let big = String(repeating: "w", count: 200 << 10)
        var bytes = ChatWire.opening
        bytes.append(ChatWire.window(cursor: 10, ids: 1...10, text: { $0 == 5 ? big : "row \($0)" }))
        for seq in 11...2_010 { bytes.append(ChatWire.op(seq, text: "small op \(seq)")) }
        try await fed.feed(bytes, chunk: 32 << 10)
        #expect(await eventually { fed.receiver.rowIds.count == 10 + 2_000 })
        let batches = fed.receiver.batches
        let framed = batches.map { $0.changes.reduce(0) { $0 + 4 + $1.count } }
        for (batch, size) in zip(batches, framed) {
            #expect(size <= AcpmuxChatRowsHost.maxBatchBytes || batch.changes.count == 1, "batch \(batch.batch): \(size) bytes in \(batch.changes.count) changes")
        }
        let window = try #require(batches.first { $0.changes.contains { $0.count > 200 << 10 } })
        #expect(window.changes.count == 1, "the window change is a batch alone")
        #expect(batches.contains { $0.changes.count > 100 }, "small ops share a batch")
        #expect(fed.receiver.rowIds == Array(1...2_010))
        print("v2.pr06 batch bound: \(batches.count) batches, largest \(framed.max() ?? 0) bytes, window change \(window.changes[0].count) bytes")
    }

    @Test("a hidden pane takes no batch; shown again, it takes and the stream goes on")
    func hiddenTakesNothing() async throws {
        let fed = FedChatRowsHost()
        #expect(await fed.host.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"))
        try await fed.feed(ChatWire.opening + ChatWire.window(cursor: 10, ids: 1...10), chunk: 1 << 20)
        #expect(await eventually { fed.receiver.rowIds.count == 10 })
        fed.host.setHidden(true)
        let calls = await fed.host.snapshotForTesting().counters.bridgeCalls
        try await fed.feed(ChatWire.op(11) + ChatWire.op(12), chunk: 1 << 20)
        // A barrier, not a wait: the driver's turn on the bytes, then the host's turn on what it got.
        await fed.driver()?.flushForTesting()
        _ = await fed.host.snapshotForTesting()
        #expect(await fed.host.snapshotForTesting().counters.bridgeCalls == calls, "no call into a hidden page")
        fed.host.setHidden(false)
        #expect(await eventually { fed.receiver.rowIds == Array(1...12) })

        // A batch the page takes while hidden is acknowledged only when it shows: nothing more is read.
        fed.receiver.hold(true)
        try await fed.feed(ChatWire.op(13), chunk: 1 << 20)
        #expect(await eventually { fed.receiver.rowIds.last == 13 })
        let batch = try #require(fed.receiver.batches.last?.batch)
        fed.host.setHidden(true)
        fed.host.taken(batch: batch)
        fed.receiver.hold(false)
        try await fed.feed(ChatWire.op(14), chunk: 1 << 20)
        // A barrier, not a wait: the driver's turn on the bytes, then the host's turn on what it got.
        await fed.driver()?.flushForTesting()
        _ = await fed.host.snapshotForTesting()
        #expect(fed.receiver.rowIds.last == 13)
        fed.host.setHidden(false)
        #expect(await eventually { fed.receiver.rowIds == Array(1...14) })
    }

    @Test("names, sids this page opened, and at most 16 subs a pane")
    func refusals() async throws {
        let fed = FedChatRowsHost()
        let open = { (sid: String) in await fed.host.open(sid: sid, request: ChatWire.request(["sid": sid, "chat": "chat-a"])) }
        #expect(await open("rows") == .failure(.name))
        #expect(await open("rows.x") == .failure(.name))
        for n in 1...16 { #expect(await open("rows.\(n)") == .success("rows.\(n)")) }
        #expect(await open("rows.1") == .failure(.name), "a held sid")
        #expect(await open("rows.17") == .failure(.limit))
        #expect(await fed.host.close(sid: "other.1") == .failure(.name))
        #expect(await fed.host.page(sid: "other.1", request: ChatWire.request(["sid": "other.1", "before": 3])) == .failure(.name))
        // Before its first window a sub cannot page: the core refuses, the page is told busy.
        #expect(await fed.host.page(sid: "rows.1", request: ChatWire.request(["sid": "rows.1", "before": 3])) == .failure(.busy))
        #expect(await fed.host.close(sid: "rows.1") == .success(()))
        #expect(await open("rows.17") == .success("rows.17"))
    }
}
