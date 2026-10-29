import CMUXMobileCore
import Foundation

/// One connection-owned workspace presence session.
public protocol WorkspacePresenceConnection: Sendable {
    /// Receives the next complete snapshot, throwing on close or malformed data.
    func receive() async throws -> WorkspacePresenceSnapshot
    /// Publishes whether the workspace is actively viewed; a newer revision wins.
    func sendViewing(_ active: Bool, revision: UInt64) async throws
    /// Unblocks receive and removes this connection's lease; safe to repeat.
    func close()
}

/// Opens connections without exposing a transport implementation to the UI model.
public protocol WorkspacePresenceConnecting: Sendable {
    /// Opens a room using the captured authenticated account credential.
    /// - Parameters:
    ///   - scope: Canonical room identity.
    ///   - accessToken: Current Stack token, never a query-string value.
    /// - Returns: A cancellable connection with no active lease until viewing is sent.
    func connect(scope: WorkspacePresenceScope, accessToken: String) async throws -> any WorkspacePresenceConnection
}

/// Failures that leave presence unavailable without affecting the workspace.
public enum WorkspacePresenceError: Error, Sendable {
    /// The frame belongs to another workspace or violates the wire contract.
    case invalidSnapshot
    /// No lease acknowledgement arrived within the server's freshness window.
    case stale
    /// The service has asked the client to retry after a bounded delay.
    case retryAfter(TimeInterval)
}
