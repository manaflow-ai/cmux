public import Foundation

/// Traces a control-socket peer to the cmux workspace whose terminal runs it.
///
/// The socket transport reports the peer's process id (`LOCAL_PEERPID`), so
/// a caller cannot choose it, unlike `CMUX_WORKSPACE_ID` or a `workspace_id`
/// parameter. The nearest process of the peer's ancestry, the peer first,
/// whose controlling terminal is a cmux terminal pane's PTY names the
/// workspace. The walk stops at the cmux process itself, at launchd, at a
/// loop and after ``maximumDepth`` processes: a process there runs in no
/// cmux terminal.
public struct BrowserReplCallerLocality {
    /// The most processes the walk visits.
    public static let maximumDepth = 64

    private let host: Int32
    private let parent: (Int32) -> Int32?
    private let workspace: (Int32) -> UUID?

    /// - Parameters:
    ///   - host: The cmux process id; the walk stops there.
    ///   - parent: The parent process id of a live process, or `nil`.
    ///   - workspace: The workspace whose terminal pane's PTY is the
    ///     process's controlling terminal, or `nil`.
    public init(host: Int32, parent: @escaping (Int32) -> Int32?, workspace: @escaping (Int32) -> UUID?) {
        self.host = host
        self.parent = parent
        self.workspace = workspace
    }

    /// The workspace of the cmux terminal `peer` runs in, or `nil` when it
    /// runs in none or the transport reported no process id.
    public func workspace(ofPeer peer: Int32?) -> UUID? {
        guard var current = peer else { return nil }
        var visited: Set<Int32> = []
        for _ in 0..<Self.maximumDepth {
            guard current > 1, current != host, visited.insert(current).inserted else { return nil }
            if let found = workspace(current) { return found }
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }
}
