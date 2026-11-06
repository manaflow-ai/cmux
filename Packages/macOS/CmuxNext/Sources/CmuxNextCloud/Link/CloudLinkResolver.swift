public import Foundation

// The one seam between a Cloud machine and the socket its daemon connection
// opens (cloud-client-contract.md 2.3, C13b). A resolver turns a machine
// into the local socket of the machine's link; `CloudLinkSession` hands that
// socket to one `DaemonConnection` per connect. Implementations:
// - `CloudCarrierResolver` (now): the session's `cmux carrier serve` socket;
// - `CloudTerminalLinkResolver` (after the Cloud pump): the daemon's
//   `apps-terminal-links` request and `apps-terminal-link` event.

/// Resolves a Cloud machine to its link socket.
public protocol CloudLinkResolver: Sendable {
    /// Opens (or reuses) the machine's link for one connect. `intent` is the
    /// connect's idempotency key, new for each connect. Throws ``CloudLinkError``.
    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket
    /// Ends the machine's link (machine removed, sign-out, quit).
    func close(_ key: CloudLinkKey) async
    /// Why the link refused a connection since the last connect, when it says (a carrier dial's step).
    func refusal(_ key: CloudLinkKey) async -> CloudLinkError?
}

extension CloudLinkResolver {
    public func refusal(_ key: CloudLinkKey) async -> CloudLinkError? { nil }
}

/// A link whose every connect fails with `error` (a capture scene's ended link).
public struct CloudEndedLinkResolver: CloudLinkResolver {
    public let error: CloudLinkError

    public init(error: CloudLinkError) { self.error = error }

    public func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket { throw error }

    public func close(_ key: CloudLinkKey) async {}
}

/// Adapter 2, after the Cloud pump lands (contract 2.3): the daemon owns one
/// relay socket per connector link and tells its clients through
/// `apps-terminal-links` and `apps-terminal-link {channel, id, target, state,
/// socket?, end?}`; `CloudLinkKey(app:target:)` matches a link to its machine.
/// Not built yet: the Cloud server opens no connector link, so there is no
/// link to find. A drop-in for ``CloudCarrierResolver``.
public struct CloudTerminalLinkResolver: CloudLinkResolver {
    public init() {}

    public func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        throw CloudLinkError.unsupported
    }

    public func close(_ key: CloudLinkKey) async {}
}
