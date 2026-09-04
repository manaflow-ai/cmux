public import Foundation

/// The process facts needed to make a top-memory ownership decision.
public struct CmuxTopMemoryProcessRecord: Equatable, Sendable {
    /// Operating-system process identifier.
    public let pid: Int
    /// Parent process identifier captured in the same sample.
    public let parentPID: Int
    /// Full executable path, when the sampler was permitted to read it.
    public let path: String?
    /// Controlling TTY device number, when present.
    public let ttyDevice: Int64?
    /// Explicit cmux workspace scope, when reported by the process.
    public let workspaceID: UUID?
    /// Explicit cmux surface scope, when reported by the process.
    public let surfaceID: UUID?
    /// Raw explicit-scope evidence code, when reported by the process.
    public let attributionReason: String?
    /// Process-group identifier captured in the same sample.
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
