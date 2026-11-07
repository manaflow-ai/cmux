import Foundation

/// Bounded viewer leases for one native conversation; each disconnect removes only its own lease.
public struct ClaudeViewerSubscriptions: Sendable {
    /// The retained attachment leases, oldest admission first.
    public let viewers: [ClaudeAttachedViewer]

    /// Loads the leases stored beside a hook session.
    /// - Parameter viewers: Existing leases; defaults to an empty session.
    public init(_ viewers: [ClaudeAttachedViewer] = []) { self.viewers = viewers }

    /// Adds a live attachment, retaining at most sixteen live leases.
    /// - Parameter viewer: The acknowledged attachment to register.
    /// - Returns: A new collection with stale generations and the same attachment ID removed.
    public func adding(_ viewer: ClaudeAttachedViewer) -> Self {
        guard viewer.viewer.isAlive, viewer.worker.isAlive else { return self }
        let kept = viewers.filter {
            $0.viewer.isAlive && $0.worker.isAlive && $0.attachmentID != viewer.attachmentID
        }
        return Self(Array((kept + [viewer]).suffix(16)))
    }

    /// Removes only one caller's attachment, leaving concurrent viewers intact.
    /// - Parameters:
    ///   - attachmentID: The closing connection's ID.
    ///   - viewerPID: The process closing that connection.
    ///   - socketPath: The local cmux instance admitting the close.
    /// - Returns: The remaining leases.
    public func removing(attachmentID: String, viewerPID: Int, socketPath: String) -> Self {
        Self(viewers.filter {
            !($0.attachmentID == attachmentID && $0.viewer.pid == viewerPID && $0.socketPath == socketPath)
        })
    }

    /// Selects up to four live candidates, newest admission first, for the existing single-target notification path.
    ///
    /// Leases are stored in admission order under the store lock, so array
    /// position is the ordering signal. Wall-clock timestamps are only
    /// metadata: a clock step between two attachments must not reorder them.
    /// - Parameters:
    ///   - workerPID: The live hook invocation PID.
    ///   - socketPath: The cmux instance receiving the hook.
    /// - Returns: Candidates whose current pane must still be corroborated by the app.
    public func candidates(workerPID: Int, socketPath: String) -> [ClaudeAttachedViewer] {
        Array(viewers.reversed().filter { $0.admits(workerPID: workerPID, socketPath: socketPath) }
            .prefix(4))
    }
}
