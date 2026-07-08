public import Foundation

/// The daemon-RPC surface the PTY bridge server needs: attach, write, detach.
///
/// Isolation design: this is a callback contract over an internally
/// queue-confined client (the legacy wire design, preserved by the lift).
/// `onEvent` and `completion` are invoked on the queue the caller supplies
/// (attach) or the client's internal queue (write); they are deliberately not
/// `@Sendable`-annotated so conformers and callers keep the legacy
/// queue-confinement contract unchanged. The protocol itself is `Sendable`
/// because clients cross queue boundaries by contract (the bridge server
/// calls it from its own rpc queue).
public protocol RemotePTYBridgeRPCClient: AnyObject, Sendable {
    /// Attaches to (or creates) a remote PTY session and starts streaming
    /// events to `onEvent` on `queue`. Throws when the attach handshake fails.
    func attachBridgePTY(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int,
        command: String?,
        requireExisting: Bool,
        queue: DispatchQueue,
        onEvent: @escaping (RemotePTYBridgeEvent) -> Void
    ) throws -> RemotePTYBridgeAttachment

    /// Writes input bytes to an attachment; `completion` receives the wire
    /// error, or `nil` on success.
    func writePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        data: Data,
        completion: @escaping ((any Error)?) -> Void
    )

    /// Detaches an attachment; fire-and-forget like the legacy client.
    func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String)
}
