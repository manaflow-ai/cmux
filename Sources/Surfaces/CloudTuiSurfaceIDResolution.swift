/// Resolution outcome for a cloud terminal's daemon-local surface identifier.
///
/// Only an explicitly unsupported modern resolver permits a compatibility-tree
/// fallback; malformed and failed responses remain fail-closed. A transport
/// deadline or a busy daemon is `retryable`: the terminal may well be alive,
/// so the caller retries on a bounded schedule instead of reporting it missing.
enum CloudTuiSurfaceIDResolution: Equatable, Sendable {
    case resolved(UInt64)
    case noPlacement
    /// The remote terminal exited (or the daemon has no record of it).
    case exited
    case unsupported
    /// The daemon did not answer in time or the answer was unusable for a
    /// reason that says nothing about the terminal itself.
    case retryable(String)
    case failed
}
