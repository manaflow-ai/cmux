public import Foundation

/// Traces a control-socket peer to the cmux workspace whose terminal runs it.
///
/// The socket transport reports the peer's process id (`LOCAL_PEERPID`), so
/// a caller cannot choose it, unlike `CMUX_WORKSPACE_ID` or a `workspace_id`
/// parameter. The nearest process of the peer's ancestry, the peer first,
/// whose controlling terminal is a cmux terminal pane's PTY names the
/// workspace. A walk that reaches the cmux process itself or launchd, or a
/// process whose parent cannot be read (it exited, or it outlived its
/// parents), found no cmux terminal: the caller is outside cmux. A walk
/// that cannot finish (a parent loop, or more than ``maximumDepth``
/// processes) proves neither, so its caller is ``Locality/unresolved`` and
/// refused, never an outside caller that may name every workspace.
public struct BrowserReplCallerLocality {
    /// The most processes the walk visits: twice the 128 ancestors the
    /// control socket's `cmuxOnly` mode walks to admit a descendant of cmux,
    /// so every peer that mode admits is resolved.
    public static let maximumDepth = 256

    /// Where a socket peer runs.
    public enum Locality: Equatable, Sendable {
        /// In a terminal pane of this workspace.
        case terminal(UUID)
        /// In no cmux terminal, or the transport reported no process id.
        case outside
        /// The walk could not finish, so neither is proven.
        case unresolved
    }

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
    /// runs in none, the transport reported no process id, or the walk
    /// could not finish (``locality(ofPeer:)`` tells those apart).
    public func workspace(ofPeer peer: Int32?) -> UUID? {
        guard case .terminal(let workspace) = locality(ofPeer: peer) else { return nil }
        return workspace
    }

    /// Where `peer` runs; see ``Locality``.
    public func locality(ofPeer peer: Int32?) -> Locality {
        guard var current = peer else { return .outside }
        var visited: Set<Int32> = []
        for _ in 0..<Self.maximumDepth {
            guard current > 1, current != host else { return .outside }
            guard visited.insert(current).inserted else { return .unresolved }
            if let found = workspace(current) { return .terminal(found) }
            guard let next = parent(current) else { return .outside }
            current = next
        }
        return .unresolved
    }
}
