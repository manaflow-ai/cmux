/// Identifies one client connection for per-connection FIFO ordering.
public struct ControlConnectionID: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Requests with no connection (tests, in-process callers).
    public static let inProcess = ControlConnectionID(rawValue: 0)

    public var description: String { "conn-\(rawValue)" }
}
