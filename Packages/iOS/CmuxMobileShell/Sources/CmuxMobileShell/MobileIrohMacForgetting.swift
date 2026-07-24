import Foundation

/// Revokes the account-owned iroh bindings for one saved computer.
///
/// Kept separate from ``MobileIrohMacDiscovering`` so the shell store depends
/// only on the narrow capability it needs. The concrete transport composition
/// discovers the account's current bindings, matches the target computer by
/// canonical device id (and exact app-instance tag when known), and revokes
/// each match through the user-ownership-scoped broker endpoint.
@MainActor
public protocol MobileIrohMacForgetting: Sendable {
    /// Revokes every non-revoked binding for one saved computer.
    ///
    /// - Parameters:
    ///   - macDeviceID: The Mac device id to forget. Canonicalized before
    ///     matching, so a raw id or a pairing-id form both resolve.
    ///   - instanceTag: When non-nil, only the matching tagged app instance is
    ///     revoked; sibling instances on the same Mac stay bound. When nil,
    ///     every instance sharing the device id is revoked.
    /// - Throws: When no account is authenticated or the broker call fails, so
    ///   the caller keeps the local row and surfaces an error instead of
    ///   claiming a revoke that never reached the server.
    func forgetComputer(macDeviceID: String, instanceTag: String?) async throws
}
