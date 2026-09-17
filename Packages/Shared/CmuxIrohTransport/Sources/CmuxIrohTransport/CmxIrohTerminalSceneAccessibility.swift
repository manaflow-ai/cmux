public import Foundation

/// Canonical visible terminal text bound to one exact semantic scene.
public struct CmxIrohTerminalSceneAccessibility: Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case zeroIdentity
        case zeroTerminalEpoch
        case zeroContentSequence
        case zeroPresentationGeneration
        case zeroPresentationSequence
        case invalidDimensions
        case textTooLarge(actual: Int, maximum: Int)
    }

    public static let maximumTextByteCount = 1_048_576

    public let terminalID: UUID
    public let terminalEpoch: UInt64
    public let contentSequence: UInt64
    public let presentationID: UUID
    public let presentationGeneration: UInt64
    public let presentationSequence: UInt64
    public let columns: UInt32
    public let rows: UInt32
    public let text: String

    public init(
        terminalID: UUID,
        terminalEpoch: UInt64,
        contentSequence: UInt64,
        presentationID: UUID,
        presentationGeneration: UInt64,
        presentationSequence: UInt64,
        columns: UInt32,
        rows: UInt32,
        text: String
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
        guard columns > 0, rows > 0 else {
            throw ValidationError.invalidDimensions
        }
        let byteCount = text.utf8.count
        guard byteCount <= Self.maximumTextByteCount else {
            throw ValidationError.textTooLarge(
                actual: byteCount,
                maximum: Self.maximumTextByteCount
            )
        }
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.contentSequence = contentSequence
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.presentationSequence = presentationSequence
        self.columns = columns
        self.rows = rows
        self.text = text
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
