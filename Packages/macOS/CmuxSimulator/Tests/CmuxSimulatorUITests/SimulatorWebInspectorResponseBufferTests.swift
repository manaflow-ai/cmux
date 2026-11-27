import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Web Inspector response buffer")
struct SimulatorWebInspectorResponseBufferTests {
    @Test("Numeric request IDs stay within JavaScript's exact integer range")
    func numericRequestIDsRequireSafeIntegers() {
        #expect(parseSimulatorWebInspectorJSONRequestID(from: "{\"id\":9007199254740991}")
            == .number("9007199254740991"))
        #expect(parseSimulatorWebInspectorJSONRequestID(from: "{\"id\":9007199254740993}") == nil)
        #expect(parseSimulatorWebInspectorJSONRequestID(from: "{\"id\":1.5}") == nil)
        #expect(parseSimulatorWebInspectorJSONRequestID(from: "{\"id\":1.0}") == .number("1"))
        #expect(parseSimulatorWebInspectorJSONRequestID(from: "{\"id\":\"9007199254740993\"}")
            == .string("9007199254740993"))
    }

    @Test("Responses are reassembled in sequence and truncated at the UI cap")
    func reassemblyAndCap() {
        let sessionID = UUID()
        let messageID = UUID()
        let payload = Data(repeating: 0x61, count: SimulatorWebInspectorResponseBuffer.maximumResponseBytes + 50)
        let chunks = SimulatorWebInspectorMessageChunker(maximumPayloadLength: 64 * 1024).chunks(
            sessionID: sessionID,
            messageID: messageID,
            payload: payload
        )
        var buffer = SimulatorWebInspectorResponseBuffer()

        for chunk in chunks.dropLast() {
            #expect(buffer.ingest(chunk, currentSessionID: sessionID) == .pending)
        }
        #expect(buffer.ingest(chunks[chunks.count - 1], currentSessionID: sessionID) == .completed)

        #expect(buffer.responses.count == 1)
        #expect(buffer.responses[0].text.utf8.count == SimulatorWebInspectorResponseBuffer.maximumResponseBytes)
        #expect(buffer.responses[0].isTruncated)
    }

    @Test("Distinct unfinished messages cannot grow the host buffer without bound")
    func pendingMessageCap() {
        let sessionID = UUID()
        var buffer = SimulatorWebInspectorResponseBuffer()

        for _ in 0..<SimulatorWebInspectorResponseBuffer.maximumPendingMessageCount {
            let chunk = SimulatorWebInspectorMessageChunk(
                sessionID: sessionID,
                messageID: UUID(),
                sequence: 0,
                isFinal: false,
                payload: Data([0x7b])
            )
            #expect(buffer.ingest(chunk, currentSessionID: sessionID) == .pending)
        }
        let overflow = SimulatorWebInspectorMessageChunk(
            sessionID: sessionID,
            messageID: UUID(),
            sequence: 0,
            isFinal: false,
            payload: Data([0x7b])
        )
        #expect(buffer.ingest(overflow, currentSessionID: sessionID) == .overflow)
    }

    @Test("Chunks from a prior worker session are ignored")
    func staleSession() {
        var buffer = SimulatorWebInspectorResponseBuffer()
        let chunk = SimulatorWebInspectorMessageChunk(
            sessionID: UUID(),
            messageID: UUID(),
            sequence: 0,
            isFinal: true,
            payload: Data("{}".utf8)
        )
        #expect(buffer.ingest(chunk, currentSessionID: UUID()) == .pending)
        #expect(buffer.responses.isEmpty)
    }

    @Test("A truncated response retains its JSON request id for correlation")
    func truncatedResponseRetainsRequestID() {
        let sessionID = UUID()
        let payload = Data(
            ("{\"id\":99,\"result\":{\"value\":\""
                + String(repeating: "x", count: SimulatorWebInspectorResponseBuffer.maximumResponseBytes + 1_000)
                + "\"}}").utf8
        )
        let chunks = SimulatorWebInspectorMessageChunker(maximumPayloadLength: 64 * 1024).chunks(
            sessionID: sessionID,
            messageID: UUID(),
            payload: payload
        )
        var buffer = SimulatorWebInspectorResponseBuffer()
        for chunk in chunks { _ = buffer.ingest(chunk, currentSessionID: sessionID) }

        #expect(buffer.responses.first?.requestID == .number("99"))
        #expect(buffer.responses.first?.isTruncated == true)
    }

    @Test("A top-level id after the retained prefix still correlates")
    func lateTopLevelRequestID() {
        let sessionID = UUID()
        let payload = Data(
            ("{\"padding\":\""
                + String(
                    repeating: "x",
                    count: SimulatorWebInspectorResponseBuffer.maximumResponseBytes + 1_000
                )
                + "\",\"id\":\"late\",\"result\":{\"ok\":true}}").utf8
        )
        let chunks = SimulatorWebInspectorMessageChunker(maximumPayloadLength: 31 * 1_024).chunks(
            sessionID: sessionID,
            messageID: UUID(),
            payload: payload
        )
        var buffer = SimulatorWebInspectorResponseBuffer()
        for chunk in chunks { _ = buffer.ingest(chunk, currentSessionID: sessionID) }

        #expect(buffer.responses.first?.requestID == .string("late"))
        #expect(buffer.responses.first?.isTruncated == true)
    }

    @Test("Nested notification ids are not mistaken for top-level response ids")
    func nestedIDIsIgnored() {
        let sessionID = UUID()
        let chunk = SimulatorWebInspectorMessageChunk(
            sessionID: sessionID,
            messageID: UUID(),
            sequence: 0,
            isFinal: true,
            payload: Data(#"{"method":"DOM.updated","params":{"request":{"id":"abc"}}}"#.utf8)
        )
        var buffer = SimulatorWebInspectorResponseBuffer()

        #expect(buffer.ingest(chunk, currentSessionID: sessionID) == .completed)
        #expect(buffer.responses.first?.requestID == nil)
    }
}
