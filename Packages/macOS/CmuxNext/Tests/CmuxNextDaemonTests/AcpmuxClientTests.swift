import Foundation
import Testing
@testable import CmuxNextAgentList

private let agentListFixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/AgentListStream")

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: agentListFixtures.appendingPathComponent(name))
}

private struct RecordedStep {
    var calls: [[String: Any]] = []
    var range: Range<Int> = 0..<0
    var changes: [Data] = []
}

private func recordedSteps(_ data: Data) throws -> [RecordedStep] {
    let prefix = Data("{\"change\":".utf8)
    var steps: [RecordedStep] = []
    for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
        let object = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        if object["step"] != nil {
            steps.append(RecordedStep())
        } else if object["call"] is String {
            try #require(!steps.isEmpty)
            steps[steps.index(before: steps.endIndex)].calls.append(object)
        } else if let feed = object["feed"] as? [Int], feed.count == 2 {
            try #require(!steps.isEmpty)
            steps[steps.index(before: steps.endIndex)].range = feed[0]..<feed[1]
        } else if line.starts(with: prefix) {
            try #require(!steps.isEmpty)
            // Data.split preserves the source indices. Drop by count so this
            // remains correct for every JSONL line after the first.
            let inner = line.dropFirst(prefix.count).dropLast()
            steps[steps.index(before: steps.endIndex)].changes.append(Data(inner))
        }
    }
    return steps
}

private func requestData(_ call: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: try #require(call["request"]))
}

private func apply(_ call: [String: Any], to client: AcpmuxClient) throws {
    switch try #require(call["call"] as? String) {
    case "subscribe_mirror":
        let result = try #require(client.subscribeMirror(try requestData(call)))
        let sid = try #require(JSONSerialization.jsonObject(with: result) as? [String: String])
        try #require(sid == ["sid": "sidebar"])
    case "want":
        try #require(client.want(try requestData(call)) == 0)
    case "unwant":
        try #require(client.unwant(try requestData(call)) == 0)
    case "connected":
        try #require(client.connected() == 0)
    case "disconnected":
        try #require(client.disconnected() == 0)
    default:
        Issue.record("unknown recorded call")
    }
}

private func drain(_ client: AcpmuxClient) -> [Data] {
    var changes: [Data] = []
    while let change = client.nextChange() { changes.append(change) }
    return changes
}

private func feed(_ bytes: Data, range: Range<Int>, to client: AcpmuxClient, chunkSize: Int) throws -> [Data] {
    var changes = drain(client)
    var carry = Data()
    var offset = range.lowerBound
    while offset < range.upperBound {
        let end = min(offset + chunkSize, range.upperBound)
        carry.append(contentsOf: bytes[offset..<end])
        offset = end

        while !carry.isEmpty {
            let result = client.received(carry)
            try #require(result.isSuccess)
            if result.consumed == 0 { break }
            try #require(result.consumed <= carry.count)
            let consumed = result.consumed
            carry.removeSubrange(carry.startIndex..<carry.index(carry.startIndex, offsetBy: consumed))
            changes.append(contentsOf: drain(client))
        }
    }
    try #require(carry.isEmpty, "recorded step left unconsumed bytes")
    changes.append(contentsOf: drain(client))
    return changes
}

private func replay(_ bytes: Data, steps: [RecordedStep], chunkSize: Int) throws -> [[Data]] {
    let client = AcpmuxClient()
    try #require(client.isAvailable)
    var actual: [[Data]] = []
    for step in steps {
        for call in step.calls { try apply(call, to: client) }
        let changes = try feed(bytes, range: step.range, to: client, chunkSize: chunkSize)
        #expect(changes == step.changes)
        actual.append(changes)
        while client.takeSend() != nil {}
    }
    return actual
}

@Suite("AcpmuxClientTests")
struct AcpmuxClientTests {
    @Test("the wrapper requires the ABI-4 header")
    func abiVersionIsPinned() {
        #expect(AcpmuxClient.expectedABIVersion == 4)
    }

    @Test("the byte driver cap is one MiB")
    func byteDriverCap() {
        #expect(AcpmuxClientByteConnection.maxUndeliveredBytes == 1 << 20)
    }

    @Test("recorded mirror is stable when fed as one chunk")
    func recordedMirrorWhole() throws {
        let bytes = try fixture("mirror.bytes")
        let steps = try recordedSteps(fixture("mirror.jsonl"))
        #expect(try replay(bytes, steps: steps, chunkSize: bytes.count) == steps.map(\.changes))
    }

    @Test("recorded mirror is stable across seven byte chunks")
    func recordedMirrorSevenByteChunks() throws {
        let bytes = try fixture("mirror.bytes")
        let steps = try recordedSteps(fixture("mirror.jsonl"))
        #expect(try replay(bytes, steps: steps, chunkSize: 7) == steps.map(\.changes))
    }

    @Test("recorded mirror is stable across one byte chunks")
    func recordedMirrorOneByteChunks() throws {
        let bytes = try fixture("mirror.bytes")
        let steps = try recordedSteps(fixture("mirror.jsonl"))
        #expect(try replay(bytes, steps: steps, chunkSize: 1) == steps.map(\.changes))
    }

    @Test("fallback leaves its recorded change available to the caller")
    func fallbackChangeIsPreserved() throws {
        let bytes = try fixture("fallback.bytes")
        let steps = try recordedSteps(fixture("fallback.jsonl"))
        try #require(steps.count == 1)
        let client = AcpmuxClient()
        try #require(client.isAvailable)
        for call in steps[0].calls { try apply(call, to: client) }
        let actual = try feed(bytes, range: steps[0].range, to: client, chunkSize: 90)
        #expect(actual == steps[0].changes)
        try #require(actual.count == 1)
        #expect(actual[0] == Data("{\"bytes\":[],\"kind\":\"fallback\"}".utf8))
    }

    @Test("10,000 returned changes are copied and freed")
    func repeatedChangeReadsStayBalanced() throws {
        let bytes = Data(try fixture("fallback.bytes").prefix(90))
        let expected = Data("{\"bytes\":[],\"kind\":\"fallback\"}".utf8)
        for _ in 0..<10_000 {
            let client = AcpmuxClient()
            try #require(client.isAvailable)
            try #require(client.connected() == 0)
            let received = client.received(bytes)
            try #require(received.isSuccess && received.consumed == bytes.count)
            try #require(client.nextChange() == expected)
            try #require(client.nextChange() == nil)
        }
    }
}
