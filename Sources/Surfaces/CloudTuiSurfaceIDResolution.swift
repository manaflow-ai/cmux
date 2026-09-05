/// Resolution outcome for a cloud terminal's daemon-local surface identifier.
///
/// Only an explicitly unsupported modern resolver permits a compatibility-tree
/// fallback; malformed, timed-out, and failed responses remain fail-closed.
enum CloudTuiSurfaceIDResolution: Equatable, Sendable {
    case resolved(UInt64)
    case noPlacement
    case unsupported
    case failed
}
