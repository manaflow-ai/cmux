/// Canonical-frontend authority used by byte-stream compatibility connections.
///
/// The compatibility connection is the delegate, never the input-lease owner.
/// Implementations must keep one canonical input owner per surface, return the
/// current text-only delegation while it remains safely before its local
/// monotonic deadline, and revoke `replacing` before returning a replacement.
/// Reusing an ID and generation requires returning the bit-for-bit unchanged
/// delegation. Renewal must revoke the old grant and return a new generation;
/// expiry or sequence fields cannot mutate in place.
/// A backend reconnect must discard every delegation from the old authority.
public protocol BackendTerminalCompatibilityInputAuthority: Sendable {
    /// Returns this exact compatibility client's current text-only delegation.
    ///
    /// - Parameters:
    ///   - surfaceID: The canonical terminal surface that owns the shared input order.
    ///   - delegateIdentity: The stable identity registered on the compatibility connection.
    ///   - replacing: The last delegation returned to this connection, if any.
    /// - Returns: A live, text-only delegation bound to `delegateIdentity`. An
    ///   unchanged generation must equal `replacing` exactly; a replacement
    ///   generation establishes a new delegate-local starting sequence.
    /// - Throws: An error when canonical input authority cannot be established safely.
    func authorizeTerminalCompatibilityInput(
        surfaceID: SurfaceID,
        delegateIdentity: BackendClientRegistrationIdentity,
        replacing: BackendTerminalInputDelegation?
    ) async throws -> BackendTerminalInputDelegation

    /// Revokes one exact delegation previously issued to a compatibility client.
    ///
    /// - Parameters:
    ///   - surfaceID: The canonical terminal surface that issued the delegation.
    ///   - delegateIdentity: The stable identity registered on the compatibility connection.
    ///   - delegation: The exact delegation generation to revoke.
    /// - Throws: An error when a still-current delegation cannot be revoked safely.
    func revokeTerminalCompatibilityInput(
        surfaceID: SurfaceID,
        delegateIdentity: BackendClientRegistrationIdentity,
        delegation: BackendTerminalInputDelegation
    ) async throws
}
