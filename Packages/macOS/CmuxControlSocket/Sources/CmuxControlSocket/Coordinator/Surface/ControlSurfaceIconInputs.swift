public import Foundation

/// The parsed lease and explicit target for a surface-icon mutation.
///
/// Requests never resolve handles or fall back to the focused surface. The
/// coordinator validates wire shapes and resource budgets before calling the
/// app's nonisolated renderer/lease seam. Direct construction does not validate.
///
/// ```swift
/// let inputs = ControlSurfaceIconInputs(
///     operation: .set, workspaceID: workspaceID, surfaceID: surfaceID,
///     ownerID: "agent-status", expectedAgentPID: 12345,
///     expectedProcessStart: "process-generation", asset: asset
/// )
/// ```
public struct ControlSurfaceIconInputs: Sendable, Equatable {
    /// The requested surface-icon lease mutation.
    public enum Operation: Sendable, Equatable {
        /// Acquire, replace, or renew a lease without changing focus.
        case set
        /// Release the matching lease without changing focus.
        case clear
    }

    /// The lease mutation to perform.
    public let operation: Operation
    /// The mandatory workspace UUID, never a handle or implicit selection.
    public let workspaceID: UUID
    /// The mandatory surface UUID, never a handle or implicit selection.
    public let surfaceID: UUID
    /// The nonempty owner identifier, bounded to 200 UTF-8 bytes by parsing.
    public let ownerID: String
    /// The existing lease token, required for asset-free renewal.
    public let leaseToken: UUID?
    /// An optional positive revision guard for compare-and-set mutations.
    public let expectedRevision: Int?
    /// The positive process ID required for every set, including renewal.
    public let expectedAgentPID: Int?
    /// The process-generation string, required for set and bounded to 80 UTF-8 bytes.
    public let expectedProcessStart: String?
    /// The lease lifetime, from 5 through 120 seconds; defaults to 30.
    public let ttlSeconds: Int
    /// The raw replacement asset, or nil for renewal and clear.
    public let asset: ControlSurfaceIconAsset?

    /// Creates transport inputs without resolving a target or rendering an asset.
    ///
    /// - Parameters:
    ///   - operation: Whether to set/renew or clear a lease.
    ///   - workspaceID: The explicit workspace UUID.
    ///   - surfaceID: The explicit surface UUID.
    ///   - ownerID: The lease owner identifier.
    ///   - leaseToken: The existing lease token, absent for acquisition.
    ///   - expectedRevision: An optional positive revision guard.
    ///   - expectedAgentPID: The process ID, mandatory on parsed set requests.
    ///   - expectedProcessStart: The process generation, mandatory on parsed set requests.
    ///   - ttlSeconds: The lease lifetime; defaults to 30 seconds.
    ///   - asset: The replacement asset, absent only for renewal or clear.
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
