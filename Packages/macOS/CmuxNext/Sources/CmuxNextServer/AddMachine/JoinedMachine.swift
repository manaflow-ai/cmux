public import Foundation

/// A machine that joined the team with a one-line join token: one `kind: "joined"` row of
/// `cmux machine list --json` (the platform's `GET /v1/machines/credentials`, merged by the CLI).
/// Every field but the id and name is optional, so an older or newer CLI still lists the row.
public nonisolated struct JoinedMachine: Identifiable, Hashable, Sendable {
    public nonisolated enum State: String, Hashable, Sendable {
        /// Its heartbeat is under two minutes old.
        case online
        case offline
        /// Its credential was revoked: it left the mesh.
        case revoked
    }

    /// The platform's machine id (`machineId`).
    public let id: String
    public let name: String
    public let state: State
    /// The last heartbeat the platform saw (RFC 3339 as sent; shown only, never compared here).
    public let lastHeartbeat: String?
    /// `macos` or `linux`, as reported at redeem.
    public let platform: String?
    public let hostname: String?
    /// The joined daemon's mesh id (the app's machine list keys a connected daemon on it).
    public let meshPeerId: String?
    /// The join token it was redeemed from (not a secret): Add Device's card flips to joined on it.
    public let joinTokenId: String?
    /// Who made the line it joined with.
    public let mintedBy: String?

    public init(id: String, name: String, state: State, lastHeartbeat: String? = nil, platform: String? = nil, hostname: String? = nil,
                meshPeerId: String? = nil, joinTokenId: String? = nil, mintedBy: String? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.lastHeartbeat = lastHeartbeat
        self.platform = platform
        self.hostname = hostname
        self.meshPeerId = meshPeerId
        self.joinTokenId = joinTokenId
        self.mintedBy = mintedBy
    }

    /// The Machines section's id of a joined machine (its row, its last check in ``MachineHealthStore``).
    public static func healthID(_ id: String) -> String { "joined:\(id)" }

    /// The joined rows of `cmux machine list --json` (a JSON array of rows of every kind); nil when
    /// the output is not that array. Rows of other kinds, and joined rows with no id, are skipped.
    public static func list(from data: Data) -> [JoinedMachine]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.compactMap(Self.init(row:))
    }

    init?(row: [String: Any]) {
        guard row["kind"] as? String == "joined" else { return nil }
        let text = { (key: String) -> String? in (row[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        guard let id = text("id") ?? text("machineId") else { return nil }
        let revoked = row["revoked"] as? Bool == true
        let state = revoked ? .revoked : text("state").flatMap(State.init(rawValue:)) ?? .offline
        self.init(id: id, name: text("name") ?? text("label") ?? text("hostname") ?? id, state: state, lastHeartbeat: text("lastHeartbeat"),
                  platform: text("platform"), hostname: text("hostname"), meshPeerId: text("meshPeerId"),
                  joinTokenId: text("joinTokenId"), mintedBy: text("mintedBy"))
    }
}
