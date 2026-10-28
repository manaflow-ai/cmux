/// The process groups to signal to release one runaway terminal session.
public struct RunawaySessionSelection: Equatable, Sendable {
    /// The session's controlling tty device.
    public let ttyDevice: Int64
    /// Physical-footprint bytes of every process on the tty.
    public let memoryBytes: Int64
    /// Number of processes in the selected groups.
    public let processCount: Int
    /// Process groups to signal, sorted ascending.
    public let processGroupIDs: [Int]
}
