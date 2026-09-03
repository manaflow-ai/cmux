import Foundation

/// Authorization retained for the root of a supervised plugin process tree.
public enum CmuxPluginProcessAuthorization: Sendable, Equatable {
    /// The process belongs to an enabled plugin session.
    case active(pluginID: String)
    /// The process was revoked and must remain denied until it exits.
    case revoked
}

/// Resolves a peer process to the supervised plugin root that owns it.
public struct CmuxPluginProcessAuthorizationResolver: Sendable {
    /// A synchronous process-parent lookup supplied by the app's Darwin seam.
    public typealias ParentProcessLookup = @Sendable (Int32) -> Int32?

    /// The root process and authorization found for a peer.
    public struct Resolution: Sendable, Equatable {
        /// The supervised root PID.
        public let rootProcessID: Int32
        /// The root's current authorization state.
        public let authorization: CmuxPluginProcessAuthorization

        /// Creates a resolution value.
        public init(rootProcessID: Int32, authorization: CmuxPluginProcessAuthorization) {
            self.rootProcessID = rootProcessID
            self.authorization = authorization
        }
    }

    private let parentProcessLookup: ParentProcessLookup

    /// Creates a resolver with the host's process-parent lookup seam.
    ///
    /// - Parameter parentProcessLookup: Returns a process's parent PID, or
    ///   `nil` when the process is no longer observable.
    public init(parentProcessLookup: @escaping ParentProcessLookup) {
        self.parentProcessLookup = parentProcessLookup
    }

    /// Resolves a peer's ancestry against supervised root authorizations.
    ///
    /// The walk is bounded and cycle-safe. The 128-level ceiling mirrors the
    /// host control-socket ancestry check, so a peer admitted as a cmux
    /// descendant cannot fall through to ordinary socket privileges merely
    /// because this plugin-specific walk used a shorter bound.
    public func resolve(
        processID: Int32,
        authorizations: [Int32: CmuxPluginProcessAuthorization]
    ) -> Resolution? {
        guard processID > 0 else { return nil }
        var current = processID
        var visited = Set<Int32>()
        for _ in 0..<128 {
            guard visited.insert(current).inserted else { return nil }
            if let authorization = authorizations[current] {
                return Resolution(rootProcessID: current, authorization: authorization)
            }
            guard let parent = parentProcessLookup(current), parent > 0, parent != current else {
                return nil
            }
            current = parent
        }
        return nil
    }
}
