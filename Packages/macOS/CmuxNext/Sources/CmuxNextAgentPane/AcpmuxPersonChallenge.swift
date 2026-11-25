import Foundation

/// A daemon's per-connection person challenge (acpmux `hub/person.rs`, cx-fcaq).
nonisolated struct AcpmuxPersonChallenge: Sendable, Equatable {
    var nonce: String
    var connection: String
    /// The daemon takes `_acpmux/person_prove` at any point of this connection's life
    /// (`personChallenge.reprove`), so a proof refused because the key reached the daemon late is
    /// sent again on this same connection, never by reconnecting.
    var reprove = false
}
