import Foundation

/// A single sampled process in a `CmuxTopProcessSnapshot`: identity, cmux
/// attribution, process-group membership, and CPU/memory/thread measurements.
public struct CmuxTopProcessInfo: Sendable {
    /// The process identifier.
    public let pid: Int
    /// The parent process identifier.
    public let parentPID: Int
    /// The process name.
    public let name: String
    /// The executable path, when process details were requested.
    public let path: String?
    /// The controlling tty device identifier, if any.
    public let ttyDevice: Int64?
    /// The cmux workspace the process is attributed to, if any.
    public let cmuxWorkspaceID: UUID?
    /// The cmux surface the process is attributed to, if any.
    public let cmuxSurfaceID: UUID?
    /// Why the process was attributed to its cmux scope, if any.
    public let cmuxAttributionReason: String?
    /// The process group identifier, if any.
    public let processGroupID: Int?
    /// The controlling terminal's foreground process group identifier, if any.
    public let terminalProcessGroupID: Int?
    /// The process CPU percentage (filled in after sampling).
    public var cpuPercent: Double
    /// The chosen memory measurement in bytes.
    public let memoryBytes: Int64
    /// Which kernel source supplied `memoryBytes`.
    public let memorySource: CmuxTopProcessMemorySource
    /// The resident memory in bytes.
    public let residentBytes: Int64
    /// Which kernel source supplied `residentBytes`.
    public let residentMemorySource: CmuxTopProcessMemorySource
    /// The virtual memory size in bytes.
    public let virtualBytes: Int64
    /// The thread count.
    public let threadCount: Int

    /// Creates a sampled-process record. `memoryBytes`/`memorySource` default from
    /// `residentBytes` when omitted, matching the kernel-source fallback order.
    public init(
        pid: Int,
        parentPID: Int,
        name: String,
        path: String?,
        ttyDevice: Int64?,
        cmuxWorkspaceID: UUID?,
        cmuxSurfaceID: UUID?,
        cmuxAttributionReason: String?,
        processGroupID: Int?,
        terminalProcessGroupID: Int?,
        cpuPercent: Double,
        memoryBytes: Int64? = nil,
        memorySource: CmuxTopProcessMemorySource? = nil,
        residentBytes: Int64,
        residentMemorySource: CmuxTopProcessMemorySource = .residentSize,
        virtualBytes: Int64,
        threadCount: Int
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.path = path
        self.ttyDevice = ttyDevice
        self.cmuxWorkspaceID = cmuxWorkspaceID
        self.cmuxSurfaceID = cmuxSurfaceID
        self.cmuxAttributionReason = cmuxAttributionReason
        self.processGroupID = processGroupID
        self.terminalProcessGroupID = terminalProcessGroupID
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes ?? residentBytes
        self.memorySource = memorySource
            ?? (memoryBytes == nil ? .residentSize : .physicalFootprint)
        self.residentBytes = residentBytes
        self.residentMemorySource = residentMemorySource
        self.virtualBytes = virtualBytes
        self.threadCount = threadCount
    }

    /// True when the process leads its controlling terminal's foreground process group.
    public var isTerminalForegroundProcessGroup: Bool {
        guard let processGroupID, let terminalProcessGroupID else { return false }
        return processGroupID == terminalProcessGroupID
    }
}
