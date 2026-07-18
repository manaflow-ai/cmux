public import Foundation

/// Bounded incremental decoder for one authenticated unidirectional byte stream.
public struct RendererControlIncrementalDecoder: Sendable {
    /// The only wire direction accepted by this stream decoder.
    public let expectedDirection: RendererControlDirection

    /// Bytes retained for the one incomplete frame, never more than the protocol maximum.
    public var bufferedByteCount: Int {
        buffer.count
    }

    /// Largest incomplete-frame buffer observed since initialization.
    public private(set) var maximumObservedBufferedByteCount = 0

    private let wire = RendererControlWire()
    private var buffer = Data()
    private var expectedFrameLength: Int?
    private var nextSequence: UInt64? = 1
    private var failed = false

    /// Creates a bounded decoder for one authenticated stream direction.
    ///
    /// - Parameter expectedDirection: The only direction permitted on the stream.
    public init(expectedDirection: RendererControlDirection) {
        self.expectedDirection = expectedDirection
    }

    /// Consumes arbitrary fragmentation or coalescing without retaining a second frame.
    ///
    /// - Parameter bytes: The next bytes read from the authenticated channel.
    /// - Returns: Zero or more complete envelopes in wire order.
    /// - Throws: ``RendererControlError`` on the first malformed field or sequence.
    public mutating func feed(_ bytes: Data) throws -> [RendererControlEnvelope] {
        guard !failed else {
            throw RendererControlError.decoderFailed
        }
        do {
            var envelopes: [RendererControlEnvelope] = []
            var inputOffset = 0
            while inputOffset < bytes.count {
                let targetLength = expectedFrameLength ?? RendererControlProtocol.headerLength
                let needed = targetLength - buffer.count
                let available = bytes.count - inputOffset
                let copyCount = min(needed, available)
                buffer.append(contentsOf: bytes[inputOffset..<(inputOffset + copyCount)])
                inputOffset += copyCount
                maximumObservedBufferedByteCount = max(maximumObservedBufferedByteCount, buffer.count)

                if expectedFrameLength == nil,
                   buffer.count == RendererControlProtocol.headerLength {
                    let (direction, sequence, frameLength) = try RendererControlWire.inspectHeader(buffer)
                    guard direction == expectedDirection else {
                        throw RendererControlError.unexpectedDirection
                    }
                    guard let expectedSequence = nextSequence else {
                        throw RendererControlError.sequenceExhausted
                    }
                    guard sequence == expectedSequence else {
                        throw RendererControlError.invalidSequence(
                            expected: expectedSequence,
                            actual: sequence
                        )
                    }
                    guard frameLength <= RendererControlProtocol.maximumFrameLength else {
                        throw RendererControlError.invalidPayloadLength
                    }
                    expectedFrameLength = frameLength
                }

                if let frameLength = expectedFrameLength, buffer.count == frameLength {
                    let envelope = try wire.decode(buffer)
                    guard envelope.direction == expectedDirection else {
                        throw RendererControlError.unexpectedDirection
                    }
                    guard let expectedSequence = nextSequence else {
                        throw RendererControlError.sequenceExhausted
                    }
                    guard envelope.sequence == expectedSequence else {
                        throw RendererControlError.invalidSequence(
                            expected: expectedSequence,
                            actual: envelope.sequence
                        )
                    }
                    envelopes.append(envelope)
                    nextSequence = expectedSequence == UInt64.max ? nil : expectedSequence + 1
                    buffer = Data()
                    expectedFrameLength = nil
                }
            }
            return envelopes
        } catch {
            failed = true
            buffer = Data()
            expectedFrameLength = nil
            throw error
        }
    }

    /// Marks the byte stream complete and rejects any truncated final frame.
    ///
    /// - Throws: ``RendererControlError/truncatedFrame`` for retained bytes.
    public mutating func finish() throws {
        guard !failed else {
            throw RendererControlError.decoderFailed
        }
        guard buffer.isEmpty else {
            failed = true
            buffer = Data()
            expectedFrameLength = nil
            throw RendererControlError.truncatedFrame
        }
    }
}
