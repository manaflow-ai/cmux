import CmuxSimulator
import Foundation

struct SimulatorWebInspectorResponseBuffer {
    static let maximumResponseBytes = SimulatorWebInspectorMessageChunk.maximumRetainedResponseBytes
    static let maximumRetainedBytes = 512 * 1024
    static let maximumResponseCount = 50
    static let maximumPendingMessageCount = 8
    static let maximumPendingBytes = 512 * 1024

    private var pending: [UUID: SimulatorPendingWebInspectorMessage] = [:]
    private(set) var responses: [SimulatorWebInspectorResponse] = []

    mutating func ingest(
        _ chunk: SimulatorWebInspectorMessageChunk,
        currentSessionID: UUID?
    ) -> SimulatorWebInspectorResponseIngestResult {
        guard chunk.sessionID == currentSessionID else { return .pending }
        let existing = pending[chunk.messageID]
        if existing == nil, pending.count >= Self.maximumPendingMessageCount {
            pending.removeAll()
            return .overflow
        }
        var value = existing ?? SimulatorPendingWebInspectorMessage(
            sessionID: chunk.sessionID,
            nextSequence: 0,
            data: Data(),
            isTruncated: false,
            requestID: nil,
            requestIDParser: SimulatorWebInspectorJSONRequestIDStreamParser()
        )
        guard value.sessionID == chunk.sessionID, chunk.sequence == value.nextSequence else {
            pending.removeValue(forKey: chunk.messageID)
            return .pending
        }
        value.nextSequence += 1
        value.requestIDParser.ingest(chunk.payload)
        value.requestID = value.requestIDParser.requestID
            ?? chunk.requestIDToken.flatMap(parseSimulatorWebInspectorJSONRequestIDToken)
        value.isTruncated = value.isTruncated || chunk.isTruncated
        let available = max(0, Self.maximumResponseBytes - value.data.count)
        if chunk.payload.count > available { value.isTruncated = true }
        if available > 0 { value.data.append(chunk.payload.prefix(available)) }

        guard chunk.isFinal else {
            let existingBytes = existing?.retainedByteCount ?? 0
            let retainedBytes = pending.values.reduce(0) { $0 + $1.retainedByteCount }
                - existingBytes
                + value.retainedByteCount
            guard retainedBytes <= Self.maximumPendingBytes else {
                pending.removeAll()
                return .overflow
            }
            pending[chunk.messageID] = value
            return .pending
        }
        pending.removeValue(forKey: chunk.messageID)
        responses.insert(SimulatorWebInspectorResponse(
            id: chunk.messageID,
            requestID: value.requestID,
            text: String(decoding: value.data, as: UTF8.self),
            isTruncated: value.isTruncated
        ), at: 0)
        trimResponses()
        return .completed
    }

    mutating func reset() {
        pending.removeAll()
        responses.removeAll()
    }

    private mutating func trimResponses() {
        if responses.count > Self.maximumResponseCount {
            responses.removeLast(responses.count - Self.maximumResponseCount)
        }
        var retained = 0
        var keep = 0
        for response in responses {
            let size = response.text.utf8.count
            guard retained + size <= Self.maximumRetainedBytes || keep == 0 else { break }
            retained += size
            keep += 1
        }
        if keep < responses.count { responses.removeLast(responses.count - keep) }
    }
}
