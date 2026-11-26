import Foundation

/// A daemon's per-connection person challenge (acpmux `hub/person.rs`, cx-fcaq).
nonisolated struct AcpmuxPersonChallenge: Sendable, Equatable {
    var nonce: String
    var connection: String
}
