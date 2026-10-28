/// One process record from the app's process census, reduced to the fields
/// runaway-session selection needs.
public struct RunawaySessionProcess: Equatable, Sendable {
    /// The process identifier.
    public let pid: Int
    /// The parent process identifier.
    public let parentPID: Int
    /// The executable name.
    public let name: String
    /// The process group, when known.
    public let processGroupID: Int?
    /// The controlling tty device, when the process has one.
    public let ttyDevice: Int64?
    /// The physical-footprint bytes.
    public let memoryBytes: Int64
    /// The start time in microseconds, when known. With `pid` it names one
    /// process for its whole life, since pids are reused.
    public let startMicroseconds: Int64?

    /// Creates a process record.
    public init(
        pid: Int,
        parentPID: Int,
        name: String,
        processGroupID: Int?,
        ttyDevice: Int64?,
        memoryBytes: Int64,
        startMicroseconds: Int64? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.processGroupID = processGroupID
        self.ttyDevice = ttyDevice
        self.memoryBytes = memoryBytes
        self.startMicroseconds = startMicroseconds
    }
}
