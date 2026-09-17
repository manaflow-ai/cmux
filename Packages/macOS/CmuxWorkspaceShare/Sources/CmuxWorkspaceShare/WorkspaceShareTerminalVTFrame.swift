public import Foundation

/// One ordered libghostty VT update for a shared terminal surface.
public struct WorkspaceShareTerminalVTFrame: Codable, Equatable, Sendable {
    /// Maximum decoded VT payload accepted by both the native host and relay.
    public static let maximumDataBytes = 1_500_000
    /// Maximum terminal dimension accepted by the web terminal renderer.
    public static let maximumDimension = 1_000
    /// Maximum number of cells allocated for one terminal viewport.
    public static let maximumCells = 200_000
    /// Largest integer that JavaScript can represent without losing precision.
    public static let maximumSafeSequence: UInt64 = 9_007_199_254_740_991

    /// Whether this frame starts a generation or depends on its predecessor.
    public enum Kind: String, Codable, Sendable {
        case snapshot
        case patch
    }

    /// Stable terminal surface identifier.
    public let surfaceId: String
    /// Generation replaced by each snapshot and shared by its dependent patches.
    public let generation: UInt64
    /// Monotonic state sequence within the terminal stream.
    public let stateSeq: UInt64
    /// Terminal grid width.
    public let columns: Int
    /// Terminal grid height.
    public let rows: Int
    /// Snapshot or dependent patch.
    public let kind: Kind
    /// Standard padded base64 encoding of the VT bytes.
    public let dataB64: String

    /// Creates a bounded terminal update safe to encode into the share protocol.
    public init(
        surfaceId: String,
        generation: UInt64,
        stateSeq: UInt64,
        columns: Int,
        rows: Int,
        kind: Kind,
        data: Data
    ) throws {
        guard UUID(uuidString: surfaceId) != nil else {
            throw WorkspaceShareTerminalVTFrameError.invalidSurfaceId
        }
        guard (1...Self.maximumSafeSequence).contains(generation),
              (1...Self.maximumSafeSequence).contains(stateSeq) else {
            throw WorkspaceShareTerminalVTFrameError.invalidSequence
        }
        guard (1...Self.maximumDimension).contains(columns),
              (1...Self.maximumDimension).contains(rows),
              columns * rows <= Self.maximumCells else {
            throw WorkspaceShareTerminalVTFrameError.invalidDimensions
        }
        guard !data.isEmpty, data.count <= Self.maximumDataBytes else {
            throw WorkspaceShareTerminalVTFrameError.invalidDataSize
        }
        self.surfaceId = surfaceId
        self.generation = generation
        self.stateSeq = stateSeq
        self.columns = columns
        self.rows = rows
        self.kind = kind
        dataB64 = data.base64EncodedString()
    }
}

/// Validation errors for an outbound shared-terminal VT update.
public enum WorkspaceShareTerminalVTFrameError: Error, Equatable, Sendable {
    case invalidSurfaceId
    case invalidSequence
    case invalidDimensions
    case invalidDataSize
}
