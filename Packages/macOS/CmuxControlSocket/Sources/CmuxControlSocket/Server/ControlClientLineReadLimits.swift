/// Resource limits applied while a socket client is not yet authorized.
public struct ControlClientLineReadLimits: Sendable {
    /// Maximum raw bytes read during the limited phase.
    public let maximumBytes: Int

    /// Absolute read budget, measured from reader creation.
    public let timeoutMilliseconds: Int

    /// Creates preauthorization read limits.
    ///
    /// - Parameters:
    ///   - maximumBytes: Maximum raw bytes, including invalid UTF-8 and delimiters.
    ///   - timeoutMilliseconds: Total time allowed before authorization
    ///     clears the limits.
    public init(maximumBytes: Int, timeoutMilliseconds: Int) {
        self.maximumBytes = maximumBytes
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}
