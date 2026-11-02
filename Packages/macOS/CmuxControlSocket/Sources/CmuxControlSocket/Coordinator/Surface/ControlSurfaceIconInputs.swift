public import Foundation

/// The parsed retained icon and explicit target for a surface-icon mutation.
///
/// Requests never resolve handles or fall back to the focused surface. The
/// coordinator validates wire shapes and resource budgets before calling the
/// app's nonisolated renderer/state seam. Direct construction does not validate.
///
/// ```swift
/// let inputs = ControlSurfaceIconInputs(
///     operation: .set, workspaceID: workspaceID, surfaceID: surfaceID,
///     ownerID: "agent-status", expectedAgentPID: 12345,
///     expectedProcessStart: "process-generation", asset: asset
/// )
/// ```
public struct ControlSurfaceIconInputs: Sendable, Equatable {
    /// The requested surface-icon mutation.
    public enum Operation: Sendable, Equatable {
        /// Set or conditionally update a retained icon without changing focus.
        case set
        /// Clear the matching icon generation without changing focus.
        case clear
    }

    /// The icon mutation to perform.
    public let operation: Operation
    /// The mandatory workspace UUID, never a handle or implicit selection.
    public let workspaceID: UUID
    /// The mandatory surface UUID, never a handle or implicit selection.
    public let surfaceID: UUID
    /// The nonempty owner identifier, bounded to 200 UTF-8 bytes by parsing.
    public let ownerID: String
    /// The current generation token, required for asset-free updates.
    public let leaseToken: UUID?
    /// An optional positive revision guard for compare-and-set mutations.
    public let expectedRevision: Int?
    /// The positive process ID required for every set, including asset-free updates.
    public let expectedAgentPID: Int?
    /// The process-generation string, required for set and bounded to 80 UTF-8 bytes.
    public let expectedProcessStart: String?
    /// Deprecated compatibility input, from 5 through 120; ignored for icon lifetime.
    public let ttlSeconds: Int
    /// The raw replacement asset, or nil for conditional no-op updates and clear.
    public let asset: ControlSurfaceIconAsset?

    /// Creates transport inputs without resolving a target or rendering an asset.
    ///
    /// - Parameters:
    ///   - operation: Whether to set/update or clear an icon.
    ///   - workspaceID: The explicit workspace UUID.
    ///   - surfaceID: The explicit surface UUID.
    ///   - ownerID: The icon owner identifier.
    ///   - leaseToken: The current generation token, absent for a full replacement.
    ///   - expectedRevision: An optional positive revision guard.
    ///   - expectedAgentPID: The process ID, mandatory on parsed set requests.
    ///   - expectedProcessStart: The process generation, mandatory on parsed set requests.
    ///   - ttlSeconds: Deprecated compatibility input; ignored for icon lifetime.
    ///   - asset: The replacement asset, absent only for conditional no-op updates or clear.
    public init(
        operation: Operation,
        workspaceID: UUID,
        surfaceID: UUID,
        ownerID: String,
        leaseToken: UUID? = nil,
        expectedRevision: Int? = nil,
        expectedAgentPID: Int? = nil,
        expectedProcessStart: String? = nil,
        ttlSeconds: Int = 30,
        asset: ControlSurfaceIconAsset? = nil
    ) {
        self.operation = operation
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.ownerID = ownerID
        self.leaseToken = leaseToken
        self.expectedRevision = expectedRevision
        self.expectedAgentPID = expectedAgentPID
        self.expectedProcessStart = expectedProcessStart
        self.ttlSeconds = ttlSeconds
        self.asset = asset
    }
}
