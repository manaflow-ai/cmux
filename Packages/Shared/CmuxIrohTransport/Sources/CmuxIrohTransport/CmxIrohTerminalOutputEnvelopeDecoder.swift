public import Foundation

/// Incremental decoder for arbitrarily chunked Iroh terminal-output bytes.
public struct CmxIrohTerminalOutputEnvelopeDecoder: Sendable {
    private var buffer = Data()
    private let codec: CmxIrohTerminalOutputEnvelopeCodec

    public init(codec: CmxIrohTerminalOutputEnvelopeCodec = CmxIrohTerminalOutputEnvelopeCodec()) {
        self.codec = codec
    }

    public var hasBufferedBytes: Bool { !buffer.isEmpty }

    public mutating func append(_ data: Data) throws -> [CmxIrohTerminalOutputEnvelope] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var envelopes: [CmxIrohTerminalOutputEnvelope] = []
        while buffer.count >= CmxIrohTerminalOutputEnvelopeCodec.headerByteCount {
            do {
                let envelope = try codec.decodePrefix(buffer)
                let frameByteCount = CmxIrohTerminalOutputEnvelopeCodec.headerByteCount
                    + envelope.payload.count
                buffer.removeFirst(frameByteCount)
                envelopes.append(envelope)
            } catch CmxIrohTerminalOutputEnvelopeCodec.DecodeError.incompleteFrame {
                break
            }
        }
        return envelopes
    }
}
