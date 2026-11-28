public import CMUXMobileCore
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
        /// Host answer to one delivered input unit on an input lane. The
        /// payload is a ``MobileTerminalInputAcknowledgement``; the sequence
        /// fields carry no terminal output. Sent only in reply to input
        /// frames that carry a delivery identity, so older phones never see it.
        case inputAcknowledgement = 3
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

    /// Wraps an input acknowledgement for the input lane.
    public static func inputAcknowledgement(
        _ acknowledgement: MobileTerminalInputAcknowledgement
    ) -> CmxIrohTerminalOutputEnvelope {
        CmxIrohTerminalOutputEnvelope(acknowledgementPayload: acknowledgement.encoded())
    }

    /// The acknowledgement body is fixed-size and its sequence range is
    /// exactly its length, so it needs none of the output validation.
    private init(acknowledgementPayload payload: Data) {
        kind = .inputAcknowledgement
        retainedBaseSequence = 0
        sequence = 0
        currentSequence = UInt64(payload.count)
        self.payload = payload
    }

    /// The acknowledgement this envelope carries, or nil for output envelopes.
    public var inputAcknowledgement: MobileTerminalInputAcknowledgement? {
        guard kind == .inputAcknowledgement else { return nil }
        return MobileTerminalInputAcknowledgement(decoding: payload)
    }
}
