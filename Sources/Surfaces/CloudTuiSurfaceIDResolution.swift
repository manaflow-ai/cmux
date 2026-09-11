/// Resolution outcome for a cloud terminal's daemon-local surface identifier.
///
/// Every outcome is an authoritative statement or an explicit "try again":
/// a transport deadline or an unusable answer is `retryable`, never "missing",
/// because the terminal may well be alive on the machine.
enum CloudTuiSurfaceIDResolution: Equatable, Sendable {
    case resolved(UInt64)
    /// The terminal is alive but no daemon view shows it. Project one, then
    /// resolve again.
    case noPlacement
    /// The remote terminal exited, or the daemon's authoritative graph has no
    /// record of it.
    case exited
    /// The daemon did not answer in time or the answer was unusable for a
    /// reason that says nothing about the terminal itself.
    case retryable(String)
}
