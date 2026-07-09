internal import Foundation

/// The seam over one remote workspace's persistent-PTY controller, through which
/// ``ControlRemotePTYWorker`` drives the five synchronous PTY operations
/// (`list` / `close` / `detach` / `start-bridge` / `resize`) without importing
/// the app target or the `RemoteSessionCoordinator` that backs it.
///
/// ## Why the seam
///
/// The legacy `v2WorkspaceRemotePTY*` bodies called the live
/// `RemoteSessionCoordinator` (an app-resolved CmuxRemoteSession controller)
/// directly: `listPTYSessions()`, `closePTYSession(sessionID:)`,
/// `detachPTYSession(...)`, `startPTYBridge(...)`, `resizePTY(...)`. The controller
/// is reached only after resolving the requested workspace's live state, so the
/// app conformer (``ControlRemotePTYReading``) hands the worker an already-bound
/// controller wrapped in this seam.
///
/// ## Isolation
///
/// `Sendable` and synchronous: the legacy PTY commands ran on the nonisolated
/// socket-worker lane and called these controller methods synchronously (each
/// blocks the calling thread on the controller queue with the legacy timeout
/// semantics, never the coordinator queue). The seam preserves that exactly: the
/// methods are `throws`, not `async`, and a thrown error is rendered into the
/// byte-identical `remote_pty_error` envelope by the worker.
public protocol ControlRemotePTYControlling: Sendable {
    /// Lists the daemon's persistent PTY sessions as raw wire dictionaries
    /// (already bridged to ``JSONValue`` by the app conformer). Matches the
    /// legacy `controller.listPTYSessions()`.
    ///
    /// - Returns: One `JSONValue.object` per session, in daemon order.
    func listPTYSessions() throws -> [JSONValue]

    /// Closes one persistent PTY session by ID. Matches
    /// `controller.closePTYSession(sessionID:)`.
    ///
    /// - Parameter sessionID: The persistent session identifier.
    func closePTYSession(sessionID: String) throws

    /// Detaches one persistent PTY attachment, leaving the session running.
    /// Matches `controller.detachPTYSession(sessionID:attachmentID:attachmentToken:)`.
    ///
    /// - Parameters:
    ///   - sessionID: The persistent session identifier.
    ///   - attachmentID: The attachment identifier.
    ///   - attachmentToken: The attachment's bearer token.
    func detachPTYSession(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String
    ) throws

    /// Starts (or reuses) a loopback PTY bridge for a persistent session,
    /// returning its endpoint. Matches
    /// `controller.startPTYBridge(sessionID:attachmentID:command:requireExisting:waitForReady:timeout:)`.
    ///
    /// - Parameters:
    ///   - sessionID: The persistent session identifier.
    ///   - attachmentID: The attachment identifier.
    ///   - command: Optional command to launch when creating the session.
    ///   - requireExisting: Refuse to create a missing session when `true`.
    ///   - waitForReady: Park the request until the daemon/proxy are ready.
    ///   - timeout: The per-operation timeout in seconds.
    /// - Returns: The bridge's loopback endpoint.
    func startPTYBridge(
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool,
        waitForReady: Bool,
        timeout: Double
    ) throws -> ControlRemotePTYBridgeEndpoint

    /// Resizes one persistent PTY attachment. Matches
    /// `controller.resizePTY(sessionID:attachmentID:attachmentToken:cols:rows:)`.
    ///
    /// - Parameters:
    ///   - sessionID: The persistent session identifier.
    ///   - attachmentID: The attachment identifier.
    ///   - attachmentToken: The attachment's bearer token.
    ///   - cols: The new column count (positive).
    ///   - rows: The new row count (positive).
    func resizePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        cols: Int,
        rows: Int
    ) throws
}
