public import Foundation

/// The process facts needed to make a top-memory ownership decision.
public struct CmuxTopMemoryProcessRecord: Equatable, Sendable {
    public let pid: Int
    public let parentPID: Int
    public let path: String?
    public let ttyDevice: Int64?
    public let workspaceID: UUID?
    public let surfaceID: UUID?
    public let attributionReason: String?
    public let processGroupID: Int?

    /// Creates a process record from trusted snapshot facts.
    public init(
        pid: Int,
        parentPID: Int,
        path: String?,
        ttyDevice: Int64?,
        workspaceID: UUID?,
        surfaceID: UUID?,
        attributionReason: String?,
        processGroupID: Int?
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.path = path
        self.ttyDevice = ttyDevice
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.attributionReason = attributionReason
        self.processGroupID = processGroupID
    }
}
