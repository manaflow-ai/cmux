/// Resource limits applied while a socket client is not yet authorized.
public struct ControlClientLineReadLimits: Sendable {
    /// Maximum UTF-8 byte count allowed before a terminating newline.
    public let maximumPendingBytes: Int

    /// Absolute read budget, measured from reader creation.
    public let timeoutMilliseconds: Int

    /// Creates preauthorization read limits.
    ///
    /// - Parameters:
    ///   - maximumPendingBytes: Maximum UTF-8 bytes in one pending line.
    ///   - timeoutMilliseconds: Total time allowed before the line is framed.
    public init(maximumPendingBytes: Int, timeoutMilliseconds: Int) {
        self.maximumPendingBytes = maximumPendingBytes
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}
