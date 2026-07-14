/// Result of a pair / unpair action on the Computers directory.
///
/// Cases are semantic (not user-facing strings) so the settings UI localizes
/// the copy while this package stays presentation-free.
public enum HivePairOutcome: Equatable, Sendable {
    /// The pairing record was written; the directory has been refreshed.
    case paired(deviceID: String)
    /// The pasted pairing link / code could not be decoded.
    case invalidLink
    /// The link decoded, but every route points back at this computer
    /// (loopback), which release builds refuse to dial.
    case loopbackRejected
    /// The link belongs to a different signed-in account than this Mac.
    case accountMismatch
    /// The registry row has no dialable route to persist.
    case noRoutes
    /// Persisting the pairing failed (local store error).
    case storeFailed
}
