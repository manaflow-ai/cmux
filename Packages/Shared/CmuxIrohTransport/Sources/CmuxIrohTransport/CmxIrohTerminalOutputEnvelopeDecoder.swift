import CmuxSafeConcurrency
public import Foundation

/// Incremental decoder for arbitrarily chunked Iroh terminal-output bytes.
public struct CmxIrohTerminalOutputEnvelopeDecoder: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// A decoded frame is longer than the buffered bytes it was decoded from: the decoder's own state is
        /// wrong, so the stream ends.
        case framePastBuffer(frameByteCount: Int, buffered: Int)
    }

    /// The first build in which a `framePastBuffer` failure traps. Not scheduled: it reports and ends the stream.
    static let frameWithinBufferFatalFromBuild = UInt64.max

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
                // decodePrefix read the whole frame from `buffer`.
                let withinBuffer = frameByteCount <= buffer.count
                Invariant.notFatalUntil(withinBuffer, "iroh-output-frame-within-buffer",
                                        build: Self.frameWithinBufferFatalFromBuild)
                guard withinBuffer else {
                    throw Failure.framePastBuffer(frameByteCount: frameByteCount, buffered: buffer.count)
                }
                buffer.removeFirst(frameByteCount)
                envelopes.append(envelope)
            } catch CmxIrohTerminalOutputEnvelopeCodec.DecodeError.incompleteFrame {
                break
            }
        }
        return envelopes
    }
}
