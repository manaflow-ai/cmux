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
    ///   - instanceTag: When non-nil, it must match the running app's build
    ///     lane. A nil value still revokes only the running build's Mac binding.
    ///   - expectedAccountID: The account that owns the row being forgotten,
    ///     captured by the caller when it read the row. The implementation must
    ///     revoke only while the live authenticated session still belongs to this
    ///     account, so an account switch landing mid-operation can never revoke a
    ///     different account's binding with the new account's credentials.
    /// - Throws: When no account is authenticated, the authenticated account no
    ///   longer matches `expectedAccountID`, or the broker call fails, so the
    ///   caller keeps the local row and surfaces an error instead of claiming a
    ///   revoke that never reached the server.
    func forgetComputer(
        macDeviceID: String,
        instanceTag: String?,
        expectedAccountID: String
    ) async throws
}
