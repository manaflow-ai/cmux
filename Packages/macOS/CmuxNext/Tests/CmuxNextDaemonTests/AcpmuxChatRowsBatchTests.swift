import Foundation
import Testing
@testable import CmuxNextAgentList

/// The recorded chat stream (acpmux `tests/v2_chat_recorded_stream.rs`).
let agentChatFixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/AgentChatStream")

/// Every recorded change of `name` (`chat.jsonl`, `fallback.jsonl`): the lines that are one JSON
/// string, each the change's exact bytes.
func recordedChatChanges(_ name: String) throws -> [Data] {
    let data = try Data(contentsOf: agentChatFixtures.appendingPathComponent(name))
    return try data.split(separator: 0x0A).filter { $0.first == UInt8(ascii: "\"") }.map { line in
        let text = try #require(try JSONSerialization.jsonObject(with: Data(line), options: .fragmentsAllowed) as? String)
        return Data(text.utf8)
    }
}

/// What a stand-in page receiver reads from the host's one call: the batch number and each change.
func receivedBatch(_ script: String) throws -> (batch: Int, changes: [Data]) {
    let head = AcpmuxChatRowsBatch.receiver + "("
    try #require(script.hasPrefix(head) && script.hasSuffix(")"))
    let body = Data(script.dropFirst(head.count).dropLast().utf8)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let batch = try #require(object["batch"] as? Int)
    let changes = try #require(object["changes"] as? [String])
    return (batch, changes.map { Data($0.utf8) })
}

@Suite("AcpmuxChatRowsBatchTests")
struct AcpmuxChatRowsBatchTests {
    @Test("a sid or blob id is <prefix>.<n> of at most 64 name bytes")
    func names() {
        for name in ["rows.1", "0123456789abcdef.12", "a-b_c.d.7", String(repeating: "a", count: 62) + ".1"] {
            #expect(AcpmuxChatRowsBatch.isName(name), "\(name)")
        }
        for name in ["", "rows", ".1", "rows.", "rows.x", "rows 1.1", "rows/1.1", "ro\u{e9}.1",
                     String(repeating: "a", count: 63) + ".1"] {
            #expect(!AcpmuxChatRowsBatch.isName(name), "\(name)")
        }
    }

    @Test("the page's call carries every recorded change byte for byte")
    func scriptKeepsEveryByte() throws {
        let changes = try recordedChatChanges("chat.jsonl") + recordedChatChanges("fallback.jsonl")
        try #require(changes.count > 20)
        try #require(changes.contains { $0.contains(0x0A) }, "a blob change holds a newline")
        let odd = Data("{\"kind\":\"chatOp\",\"x\":\"\u{2028}\u{2029}\t\u{1}\\\\\"}".utf8)
        let script = AcpmuxChatRowsBatch.script(batch: 7, changes: changes + [odd])
        let received = try receivedBatch(script)
        #expect(received.batch == 7)
        #expect(received.changes == changes + [odd])
        #expect(!script.contains("\u{2028}") && !script.contains("\n"))
    }

    @Test("a change's kind is read without parsing it")
    func kindMatchesAParse() throws {
        let changes = try recordedChatChanges("chat.jsonl") + recordedChatChanges("fallback.jsonl")
        for change in changes {
            let head = change.split(separator: 0x0A, maxSplits: 1).first.map { Data($0) } ?? change
            let parsed = try #require(try JSONSerialization.jsonObject(with: head) as? [String: Any])
            #expect(AcpmuxChatRowsBatch.kind(of: change) == parsed["kind"] as? String)
        }
        #expect(AcpmuxChatRowsBatch.kind(of: changes.last ?? Data()) == "fallback")
    }

    @Test("a framed batch splits into its changes, and a torn one is refused")
    func framedSplit() throws {
        let changes = try recordedChatChanges("chat.jsonl")
        var framed = Data()
        for change in changes {
            withUnsafeBytes(of: UInt32(change.count).bigEndian) { framed.append(contentsOf: $0) }
            framed.append(change)
        }
        #expect(AcpmuxChatRowsBatch.changes(inFramed: framed) == changes)
        #expect(AcpmuxChatRowsBatch.changes(inFramed: framed.dropLast()) == nil)
        #expect(AcpmuxChatRowsBatch.changes(inFramed: Data()) == [])
    }
}
