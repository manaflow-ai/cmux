public import Foundation

/// The explicitly noncanonical terminal byte stream exported for compatibility clients.
///
/// These bytes reproduce terminal state in another parser, but the daemon's
/// canonical Ghostty parser remains authoritative. A generation change carries
/// a complete replacement replay and must never be spliced into the preceding
/// generation as ordinary output.
public enum BackendTerminalCompatibilityEvent: Equatable, Sendable {
    case snapshot(BackendTerminalCompatibilitySnapshot)
    case output(BackendTerminalCompatibilityOutput)
    case replacement(BackendTerminalCompatibilitySnapshot)
    case colorsChanged(BackendTerminalCompatibilityColors)
}

/// One complete VT replay captured atomically with its following byte cursor.
public struct BackendTerminalCompatibilitySnapshot: Equatable, Sendable {
    public static let fidelity = "noncanonical-byte-stream"

    public let surfaceID: SurfaceID
    public let runtimeEpoch: UInt64
    public let generation: UInt64
    public let sequence: UInt64
    public let columns: UInt16
    public let rows: UInt16
    public let replay: Data

    public init(
        surfaceID: SurfaceID,
        runtimeEpoch: UInt64,
        generation: UInt64,
        sequence: UInt64,
        columns: UInt16,
        rows: UInt16,
        replay: Data
    ) {
        self.surfaceID = surfaceID
        self.runtimeEpoch = runtimeEpoch
        self.generation = generation
        self.sequence = sequence
        self.columns = columns
        self.rows = rows
        self.replay = replay
    }
}

/// One contiguous raw-output range in a single runtime and replay generation.
public struct BackendTerminalCompatibilityOutput: Equatable, Sendable {
    public let surfaceID: SurfaceID
    public let runtimeEpoch: UInt64
    public let generation: UInt64
    public let startSequence: UInt64
    public let nextSequence: UInt64
    public let data: Data

    public init(
        surfaceID: SurfaceID,
        runtimeEpoch: UInt64,
        generation: UInt64,
        startSequence: UInt64,
        nextSequence: UInt64,
        data: Data
    ) {
        self.surfaceID = surfaceID
        self.runtimeEpoch = runtimeEpoch
        self.generation = generation
        self.startSequence = startSequence
        self.nextSequence = nextSequence
        self.data = data
    }
}

/// A palette update fenced to the exact runtime, generation, and byte cursor.
public struct BackendTerminalCompatibilityColors: Equatable, Sendable {
    public let surfaceID: SurfaceID
    public let runtimeEpoch: UInt64
    public let generation: UInt64
    public let sequence: UInt64
    public let fields: [String: BackendJSONValue]

    public init(
        surfaceID: SurfaceID,
        runtimeEpoch: UInt64,
        generation: UInt64,
        sequence: UInt64,
        fields: [String: BackendJSONValue]
    ) {
        self.surfaceID = surfaceID
        self.runtimeEpoch = runtimeEpoch
        self.generation = generation
        self.sequence = sequence
        self.fields = fields
    }
}

/// Fail-closed validation errors for one dedicated compatibility connection.
public enum BackendTerminalCompatibilityError: Error, Equatable, Sendable {
    case alreadyAttached
    case notAttached
    case eventsAlreadyClaimed
    case missingExactPeerExpectation
    case incompatibleBackend
    case surfaceNotFound(SurfaceID)
    case surfaceIsNotTerminal(SurfaceID)
    case invalidEvent(String)
    case streamOverflow(capacity: Int)
    case inputTooLarge(maximumBytes: Int)
}
