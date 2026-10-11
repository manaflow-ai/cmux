public import Foundation

public nonisolated enum ServerConnection: Sendable, Equatable {
    case connecting
    case connected
    /// The local server role is unreachable (not installed, stopped).
    case unavailable(String)
}

public nonisolated enum ServerSourceEvent: Sendable {
    case connection(ServerConnection)
    case snapshot(ServerSnapshot)
    /// Answer to `lookupCode`: the pending server, or nil when no pairing
    /// has that code.
    case candidate(PairingCandidate?)
    /// The owner's answer to an intent: `reject` is nil on success.
    case settled(key: String, reject: String?)
    /// Where the user's Chief runs (a paired server), or nil when no chief
    /// is placed on one or the user is signed out.
    case chief(ChiefPlacementStatus?)
}
