public import Foundation

// The one seam between a Cloud machine and the socket its daemon connection
// opens (cloud-client-contract.md 2.3, C13b). A resolver turns a machine
// into the local socket of the machine's link; `CloudLinkSession` hands that
// socket to one `DaemonConnection` per connect. `CloudCarrierResolver` is the one
// implementation: the session's `cmux carrier serve` socket, whose dial, reconnect and
// resume run in Rust (cmux-tui `carrier/`).

/// Resolves a Cloud machine to its link socket.
public protocol CloudLinkResolver: Sendable {
    /// Opens (or reuses) the machine's link for one connect. `intent` is the
    /// connect's idempotency key, new for each connect. Throws ``CloudLinkError``.
    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket
    /// Ends the machine's link (machine removed or paused, sign-out, quit). A later `open` starts it again.
    func close(_ key: CloudLinkKey) async
    /// Why the link refused a connection since the last connect, when it says (a carrier dial's step).
    func refusal(_ key: CloudLinkKey) async -> CloudLinkError?
    /// True when the socket dials the machine once per connection (the carrier): the daemon connection's
    /// retry and reconnect get the same socket again until ``refusal(_:)`` names why the link ended.
    var redials: Bool { get }
    /// Hands the link newer answers about the caller (a carrier connection's `vmk`) as they come.
    func observeOwnership(_ key: CloudLinkKey, _ update: @escaping @Sendable (CloudCallerOwnership) async -> Void) async
    /// The machine's carrier socket for another local client (the Cloud app server's streams and file ops),
    /// started when it does not run, without touching this link's state. Throws ``CloudLinkError``.
    func carrierSocket(_ key: CloudLinkKey) async throws -> String
}

extension CloudLinkResolver {
    public func refusal(_ key: CloudLinkKey) async -> CloudLinkError? { nil }
    public var redials: Bool { false }
    public func observeOwnership(_ key: CloudLinkKey, _ update: @escaping @Sendable (CloudCallerOwnership) async -> Void) async {}
    public func carrierSocket(_ key: CloudLinkKey) async throws -> String { throw CloudLinkError.unsupported }
}

/// A link whose every connect fails with `error` (a capture scene's ended link).
public struct CloudEndedLinkResolver: CloudLinkResolver {
    public let error: CloudLinkError

    public init(error: CloudLinkError) { self.error = error }

    public func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket { throw error }

    public func close(_ key: CloudLinkKey) async {}
}
