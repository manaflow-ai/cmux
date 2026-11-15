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

private final class LockedData: @unchecked Sendable {
    let lock = NSLock()
    var value = Data()
}

/// The recorded JSONL wraps each client change in {"change": ...}. The C
/// client emits the inner object, so preserve its bytes instead of parsing and
/// re-encoding it (key order is part of this receipt).
private func expectedChanges(_ data: Data) -> Data {
    let prefix = Data("{\"change\":".utf8)
    var result = Data()
    for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
        guard line.starts(with: prefix), line.count > prefix.count else { continue }
        result.append(contentsOf: line[prefix.count..<(line.count - 1)])
        result.append(0x0A)
    }
    if result.last == 0x0A { result.removeLast() }
    return result
}

private func replay(_ bytes: Data, chunkSize: Int, expected: Data) -> Data {
    let client = AcpmuxClient()
    guard client.isAvailable else { return Data() }
    _ = client.connected()
    let driver = AcpmuxClientByteConnection(client: client)
    let done = DispatchSemaphore(value: 0)
    let received = LockedData()
    driver.beginForTesting {
        received.lock.lock()
        received.value.append(contentsOf: $0)
        let complete = received.value == expected
        received.lock.unlock()
        driver.acknowledgeBatch()
        if complete { done.signal() }
    }
    var offset = 0
    while offset < bytes.count {
        let end = min(offset + chunkSize, bytes.count)
        driver.feedForTesting(Data(bytes[offset..<end]))
        offset = end
    }
    _ = done.wait(timeout: .now() + 20)
    received.lock.lock()
    defer { received.lock.unlock() }
    return received.value
}

@Test("the wrapper requires the ABI-3 header")
func abiVersionIsPinned() {
    #expect(AcpmuxClient.expectedABIVersion == 3)
}

@Test("the byte driver cap is one MiB")
func byteDriverCap() {
    #expect(AcpmuxClientByteConnection.maxUndeliveredBytes == 1 << 20)
}

@Test("recorded mirror is stable when fed as one chunk")
func recordedMirrorWhole() throws {
    let bytes = try fixture("mirror.bytes")
    let expected = expectedChanges(try fixture("mirror.jsonl"))
    #expect(replay(bytes, chunkSize: bytes.count, expected: expected) == expected)
}

@Test("recorded mirror is stable across seven byte chunks")
func recordedMirrorSevenByteChunks() throws {
    let bytes = try fixture("mirror.bytes")
    let expected = expectedChanges(try fixture("mirror.jsonl"))
    #expect(replay(bytes, chunkSize: 7, expected: expected) == expected)
}

@Test("recorded mirror is stable across one byte chunks")
func recordedMirrorOneByteChunks() throws {
    let bytes = try fixture("mirror.bytes")
    let expected = expectedChanges(try fixture("mirror.jsonl"))
    #expect(replay(bytes, chunkSize: 1, expected: expected) == expected)
}

@Test("fallback leaves its change available to the caller")
func fallbackChangeIsPreserved() throws {
    let client = AcpmuxClient()
    guard client.isAvailable else { return }
    _ = client.connected()
    let bytes = try fixture("fallback.bytes")
    let result = client.received(bytes)
    #expect(result.isSuccess)
    var change: Data?
    while let next = client.nextChange() { change = next; break }
    let expected = expectedChanges(try fixture("fallback.jsonl"))
    #expect(change == expected)
}

@Test("the C change take/free path remains callable under repeated reads")
func repeatedChangeReadsStayBalanced() {
    let client = AcpmuxClient()
    guard client.isAvailable else { return }
    _ = client.connected()
    for _ in 0..<10_000 { _ = client.nextChange() }
    #expect(client.nextChange() == nil)
}
