/// One sequenced renderer-control message in an authenticated direction.
public struct RendererControlEnvelope: Equatable, Sendable {
    /// Direction authenticated by the surrounding IPC channel.
    public let direction: RendererControlDirection

    /// Exact contiguous sequence within that direction, starting at one.
    public let sequence: UInt64

    /// Typed command or reply.
    public let message: RendererControlMessage

    /// Creates a validated renderer-control envelope.
    ///
    /// - Parameters:
    ///   - direction: Authenticated message direction.
    ///   - sequence: Nonzero contiguous per-direction sequence.
    ///   - message: Typed command or reply.
    /// - Throws: ``RendererControlError`` when direction or sequence is invalid.
    public init(
        direction: RendererControlDirection,
        sequence: UInt64,
        message: RendererControlMessage
    ) throws {
        guard sequence != 0 else {
            throw RendererControlError.invalidSequence(expected: 1, actual: 0)
        }
        guard message.direction == direction else {
            throw RendererControlError.unexpectedDirection
        }
        self.direction = direction
        self.sequence = sequence
        self.message = message
    }
}
