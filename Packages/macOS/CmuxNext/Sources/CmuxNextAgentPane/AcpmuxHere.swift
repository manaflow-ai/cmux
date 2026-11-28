public import Foundation

/// Wire values from acpmux's `protocol/here.rs`. Status reduction stays in Rust.
public nonisolated struct AcpmuxHere: Decodable, Sendable, Equatable {
    public let here: [Member]
    /// Nil means unavailable (including older daemons). Empty means no peer has
    /// exchanged state yet; neither value proves that all replicas are synced.
    public let sync: [SyncPeer]?
    /// The daemon's one reduction of `here` and `sync` for the sidebar's status icon (RFD 0140).
    /// Nil from a daemon that predates it; clients draw it and never re-derive it from `sync`.
    public let summary: Summary?

    init(result: [String: Any]) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: result))
    }

    public nonisolated struct Member: Decodable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let kind: Kind
        public let status: Status
        public let working: Bool
        public let devices: [Device]
    }

    public nonisolated struct Device: Decodable, Sendable, Equatable {
        public let device: String
        public let deviceKind: DeviceKind
        public let status: Status
        public let working: Bool
        /// Milliseconds since the last beat, on the daemon's clock.
        public let ageMs: UInt64
    }

    public nonisolated struct SyncPeer: Decodable, Sendable, Equatable {
        public let peer: String
        public let connected: Bool
        /// The last exchanged vectors were equal at this read. This is not
        /// connectivity; a disconnected peer can have unseen offline edits.
        public let acknowledged: Bool
        /// Local edit sequences not covered by the peer's last acknowledgement.
        public let unacknowledgedEdits: UInt64
    }

    public nonisolated struct Summary: Decodable, Sendable, Equatable {
        public let sync: SyncState
        /// Offline: the most edits any peer misses. Syncing: the most any connected peer misses. Else 0.
        public let pendingEdits: UInt64
        /// People here besides this machine's own person.
        public let others: UInt32
        public let agents: UInt32
    }

    public nonisolated enum SyncState: String, Decodable, Sendable {
        case offline, syncing, synced, alone, unknown

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .unknown
        }
    }

    // The daemon can update before the app. New string values must not discard
    // the rest of a presence snapshot; malformed non-string values still throw.
    public nonisolated enum Kind: String, Decodable, Sendable {
        case person, agent, unknown

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .unknown
        }
    }

    public nonisolated enum Status: String, Decodable, Sendable {
        case active, idle, away, unknown

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .unknown
        }
    }

    public nonisolated enum DeviceKind: String, Decodable, Sendable {
        case mac, vm, phone, web, other, unknown

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .unknown
        }
    }
}
