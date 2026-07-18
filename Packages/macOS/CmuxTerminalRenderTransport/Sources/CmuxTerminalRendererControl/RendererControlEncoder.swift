public import Foundation

/// Stateful sender that assigns exact contiguous sequence values in one direction.
public struct RendererControlEncoder: Sendable {
    /// The immutable direction encoded by this sender.
    public let direction: RendererControlDirection

    private let wire = RendererControlWire()
    private var nextSequence: UInt64? = 1

    /// Creates a sender for one authenticated unidirectional channel.
    ///
    /// - Parameter direction: The only message direction this sender accepts.
    public init(direction: RendererControlDirection) {
        self.direction = direction
    }

    /// Encodes a message and advances the sequence only after successful validation.
    ///
    /// - Parameter message: A typed message valid for this sender's direction.
    /// - Returns: One complete length-prefixed frame.
    /// - Throws: ``RendererControlError`` when direction, fields, or sequence are invalid.
    public mutating func encode(_ message: RendererControlMessage) throws -> Data {
        guard message.direction == direction else {
            throw RendererControlError.unexpectedDirection
        }
        guard let sequence = nextSequence else {
            throw RendererControlError.sequenceExhausted
        }
        let frame = try wire.encode(RendererControlEnvelope(
            direction: direction,
            sequence: sequence,
            message: message
        ))
        nextSequence = sequence == UInt64.max ? nil : sequence + 1
        return frame
    }
}
