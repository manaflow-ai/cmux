/// Why the mobile shell is showing the disconnected screen.
///
/// The disconnected screen renders only once the launch reconnect attempt has
/// resolved without a live connection, but historically it could not say *why*.
/// This three-way split lets the view show accurate copy and the right
/// affordance: pairing guidance for a device that has never paired a Mac, an
/// offline/asleep message with a reconnect control for a known Mac that is
/// currently unreachable, and a bounded reconnect indicator while an attempt is
/// actively in flight.
///
/// Classified by ``DisconnectedShellPolicy``.
public enum DisconnectedShellState: Equatable, Sendable {
    /// No Mac is on record for this device: there is nothing to reconnect to, so
    /// the user is guided to pair a Mac.
    case neverPaired
    /// A Mac is on record but currently unreachable (offline, asleep, or its
    /// route went stale). The user gets an offline/asleep message and a reconnect
    /// control.
    case offline
    /// A reconnect attempt is actively running. A bounded, indeterminate
    /// indicator is shown rather than the offline message.
    case reconnecting
}
