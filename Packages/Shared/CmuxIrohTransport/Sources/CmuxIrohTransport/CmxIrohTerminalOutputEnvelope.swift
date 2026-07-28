public import Foundation

/// One bounded, sequence-aware terminal-output frame on an Iroh application lane.
///
/// The first frame on every lane is ``Kind/replay``. Its retained-base and
/// current sequences let the receiver prove that the requested cursor was
/// covered by the Mac's bounded history. Later ``Kind/chunk`` frames retain the
/// same explicit sequence boundaries, so QUIC receive chunking cannot hide a
/// duplicate or gap.
public struct CmxIrohTerminalOutputEnvelope: Equatable, Sendable {
    public enum Kind: UInt8, Equatable, Sendable {
        case replay = 1
        case chunk = 2
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidSequenceRange
        case payloadLengthMismatch(expected: UInt64, actual: Int)
        case payloadTooLarge(actual: Int, maximum: Int)
    }

    public static let maximumPayloadByteCount = 256 * 1_024

    public let kind: Kind
    public let retainedBaseSequence: UInt64
    public let sequence: UInt64
    public let currentSequence: UInt64
    public let payload: Data

    public init(
        kind: Kind,
        retainedBaseSequence: UInt64,
        sequence: UInt64,
        currentSequence: UInt64,
        payload: Data
    ) throws {
        guard retainedBaseSequence <= sequence,
              sequence <= currentSequence else {
            throw ValidationError.invalidSequenceRange
        }
        let expectedPayloadLength = currentSequence - sequence
        guard expectedPayloadLength == UInt64(payload.count) else {
            throw ValidationError.payloadLengthMismatch(
                expected: expectedPayloadLength,
                actual: payload.count
            )
        }
        guard payload.count <= Self.maximumPayloadByteCount else {
            throw ValidationError.payloadTooLarge(
                actual: payload.count,
                maximum: Self.maximumPayloadByteCount
            )
        }
        self.kind = kind
        self.retainedBaseSequence = retainedBaseSequence
        self.sequence = sequence
        self.currentSequence = currentSequence
        self.payload = payload
    }
}
