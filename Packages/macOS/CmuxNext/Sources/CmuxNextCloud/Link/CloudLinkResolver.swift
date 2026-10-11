public import Foundation

// The one seam between a Cloud machine and the socket its daemon connection
// opens (cloud-client-contract.md 2.3, C13b). A resolver turns a machine
// into the local socket of the machine's link; `CloudLinkSession` hands that
// socket to one `DaemonConnection` per connect. Implementations:
// - `CloudConnectOpResolver` (now): the Cloud app server's
//   `cloud.machine.connect` answer field `socket` (the carrier socket);
// - `CloudTerminalLinkResolver` (after the Cloud pump): the daemon's
//   `apps-terminal-links` request and `apps-terminal-link` event.

/// Runs one op of the Cloud app server (`apps-run` on the local daemon) and
/// returns its result as JSON. String args only: the link ops take ids.
/// Throws ``CloudAppOpError`` for an op error.
public typealias CloudAppOpRunner = @Sendable (_ op: String, _ args: [String: String], _ idempotencyKey: String,
                                               _ origin: CloudLinkOrigin) async throws -> Data

/// Resolves a Cloud machine to its link socket.
public protocol CloudLinkResolver: Sendable {
    /// Opens (or reuses) the machine's link for one connect. `intent` is the
    /// connect's idempotency key, new for each connect. Throws ``CloudLinkError``.
    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket
    /// Ends the machine's link (machine removed, sign-out, quit).
    func close(_ key: CloudLinkKey) async
}

/// Adapter 2, after the Cloud pump lands (contract 2.3): the daemon owns one
/// relay socket per connector link and tells its clients through
/// `apps-terminal-links` and `apps-terminal-link {channel, id, target, state,
/// socket?, end?}`; `CloudLinkKey(app:target:)` matches a link to its machine.
/// Not built yet: the Cloud server opens no connector link, so there is no
/// link to find. A drop-in for ``CloudConnectOpResolver``.
public struct CloudTerminalLinkResolver: CloudLinkResolver {
    public init() {}

    public func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        throw CloudLinkError.unsupported
    }

    public func close(_ key: CloudLinkKey) async {}
}
