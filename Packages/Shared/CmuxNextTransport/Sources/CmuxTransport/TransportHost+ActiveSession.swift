import Foundation

extension TransportHost {
    /// Snapshot of one admitted session; the host owns its service-task lifecycle.
    public struct ActiveSession: Sendable {
        /// Admission identifier, unique to this session generation.
        public let id: String
        /// Connection carrying this session's control and application lanes.
        public let connection: any PeerConnection
        /// Kept for in-session renewal verification (3.6c): a renewal must be
        /// for the SAME key, device, and app the session was admitted with.
        public var deviceKey: Data
        /// Currently accepted grant, replaced only by a validated renewal.
        public var grant: PairingGrant
        /// Whether the current grant has already received its pre-expiry warning.
        public var warnedExpiring = false
        /// The per-session service loops (control, echo, chat). Stored so
        /// every removal path can CANCEL them: on a half-open connection the
        /// lanes never EOF, and unstored loops outlive the session forever.
        var serviceTasks: [Task<Void, Never>] = []

        func cancelServices() {
            for task in serviceTasks { task.cancel() }
        }
    }

}
