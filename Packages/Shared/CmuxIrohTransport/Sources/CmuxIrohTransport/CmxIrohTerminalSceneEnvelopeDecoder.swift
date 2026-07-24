public import Foundation

/// Incrementally decodes arbitrarily chunked semantic-scene lane bytes.
public struct CmxIrohTerminalSceneEnvelopeDecoder: Sendable {
    private static let maximumAppendSliceByteCount = 256 * 1_024

    private var buffer = Data()
    private let codec: CmxIrohTerminalSceneEnvelopeCodec

    public init(
        codec: CmxIrohTerminalSceneEnvelopeCodec = CmxIrohTerminalSceneEnvelopeCodec()
    ) {
        self.codec = codec
    }

    /// Whether an incomplete record is currently retained.
    public var hasBufferedBytes: Bool { !buffer.isEmpty }

    /// Appends network bytes and returns every complete envelope in order.
    public mutating func append(_ data: Data) throws -> [CmxIrohTerminalSceneEnvelope] {
        guard !data.isEmpty else { return [] }
        var envelopes: [CmxIrohTerminalSceneEnvelope] = []
        var offset = 0
        while offset < data.count {
            let available = CmxIrohTerminalSceneEnvelopeCodec.maximumFrameByteCount
                - buffer.count
            guard available > 0 else {
                throw CmxIrohTerminalSceneEnvelopeCodec.DecodeError.payloadTooLarge(
                    actual: buffer.count + 1,
                    maximum: CmxIrohTerminalSceneEnvelopeCodec.maximumFrameByteCount
                )
            }
            let count = min(
                data.count - offset,
                available,
                Self.maximumAppendSliceByteCount
            )
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: count)
            buffer.append(data[start ..< end])
            offset += count
            envelopes.append(contentsOf: try drainCompleteEnvelopes())
        }
        return envelopes
    }

    /// Proves that the peer ended exactly between records.
    public mutating func finish() throws {
        guard buffer.isEmpty else {
            throw CmxIrohTerminalSceneEnvelopeCodec.DecodeError.incompleteFrame
        }
    }

    private mutating func drainCompleteEnvelopes() throws
        -> [CmxIrohTerminalSceneEnvelope]
    {
        var envelopes: [CmxIrohTerminalSceneEnvelope] = []
        while buffer.count >= CmxIrohTerminalSceneEnvelopeCodec.headerByteCount {
            do {
                let decoded = try codec.decodePrefix(buffer)
                buffer.removeFirst(decoded.consumedByteCount)
                envelopes.append(decoded.envelope)
            } catch CmxIrohTerminalSceneEnvelopeCodec.DecodeError.incompleteFrame {
                break
            }
        }
        return envelopes
    }
}
