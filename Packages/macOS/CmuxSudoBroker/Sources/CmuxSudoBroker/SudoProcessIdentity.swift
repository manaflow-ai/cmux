/// A PID paired with its creation time to reject PID reuse during recovery.
public struct SudoProcessIdentity: Codable, Sendable, Hashable {
    /// The process identifier.
    public let processIdentifier: Int32

    /// The process start time in whole Unix seconds.
    public let startSeconds: Int64

    /// The microsecond component of the process start time.
    public let startMicroseconds: Int32

    /// Creates a generation-safe process identity.
    ///
    /// - Parameters:
    ///   - processIdentifier: The process identifier captured at inspection time.
    ///   - startSeconds: The whole-second component of the process start time.
    ///   - startMicroseconds: The microsecond component of the process start time.
    public init(processIdentifier: Int32, startSeconds: Int64, startMicroseconds: Int32) {
        self.processIdentifier = processIdentifier
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}
