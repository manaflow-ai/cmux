import Foundation

/// How a page's content process ended.
public struct BrowserPageProcessExit: Equatable, Hashable, Sendable {
    /// Why the process ended.
    public enum Kind: Equatable, Hashable, Sendable {
        /// The process crashed.
        case crashed
        /// The system or the user killed the process.
        case killed
        /// The process ran out of memory.
        case outOfMemory
        /// Any other abnormal end.
        case other
    }

    /// Why the process ended.
    public var kind: Kind
    /// The process exit status, when the engine reports one.
    public var status: Int32?

    /// Creates a process exit description.
    /// - Parameters:
    ///   - kind: Why the process ended.
    ///   - status: The exit status, or `nil` when unknown.
    public init(kind: Kind, status: Int32? = nil) {
        self.kind = kind
        self.status = status
    }
}
