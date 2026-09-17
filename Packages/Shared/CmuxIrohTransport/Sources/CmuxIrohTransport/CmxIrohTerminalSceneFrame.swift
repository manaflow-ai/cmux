public import Foundation

/// One bounded Ghostty semantic scene with exact terminal and presentation fences.
public struct CmxIrohTerminalSceneFrame: Equatable, Sendable {
    /// Canonical section kind encoded by Ghostty.
    public enum Kind: UInt8, Equatable, Sendable {
        case full = 1
        case delta = 2
        case unchanged = 3
    }

    /// Validation failures caught before a scene enters a renderer.
    public enum ValidationError: Error, Equatable, Sendable {
        case zeroIdentity
        case zeroTerminalEpoch
        case zeroContentSequence
        case zeroPresentationGeneration
        case zeroPresentationSequence
        case emptyPayload
        case payloadTooLarge(actual: Int, maximum: Int)
    }

    /// Largest opaque Ghostty scene accepted from the host.
    public static let maximumPayloadByteCount = 64 * 1_024 * 1_024

    public let terminalID: UUID
    public let terminalEpoch: UInt64
    public let contentSequence: UInt64
    public let presentationID: UUID
    public let presentationGeneration: UInt64
    public let presentationSequence: UInt64
    public let kind: Kind
    public let payload: Data

    /// Creates one validated semantic scene frame.
    public init(
        terminalID: UUID,
        terminalEpoch: UInt64,
        contentSequence: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        presentationSequence: UInt64,
        kind: Kind,
        payload: Data
    ) throws {
        guard terminalID != Self.zeroUUID, presentationID != Self.zeroUUID else {
            throw ValidationError.zeroIdentity
        }
        guard terminalEpoch != 0 else {
            throw ValidationError.zeroTerminalEpoch
        }
        guard contentSequence != 0 else {
            throw ValidationError.zeroContentSequence
        }
        guard presentationGeneration != 0 else {
            throw ValidationError.zeroPresentationGeneration
        }
        guard presentationSequence != 0 else {
            throw ValidationError.zeroPresentationSequence
        }
        guard !payload.isEmpty else {
            throw ValidationError.emptyPayload
        }
        guard payload.count <= Self.maximumPayloadByteCount else {
            throw ValidationError.payloadTooLarge(
                actual: payload.count,
                maximum: Self.maximumPayloadByteCount
            )
        }
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.contentSequence = contentSequence
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.presentationSequence = presentationSequence
        self.kind = kind
        self.payload = payload
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
