public import Foundation

/// A machine that joined the team with a one-line join token: one `kind: "joined"` row of
/// `cmux machine list --json` (the platform's `GET /v1/machines/credentials`, merged by the CLI).
/// Every field but the id and name is optional, so an older or newer CLI still lists the row.
public nonisolated struct JoinedMachine: Identifiable, Hashable, Sendable {
    public nonisolated enum State: String, Hashable, Sendable {
        /// Its last heartbeat is within ``JoinedMachine/onlineWindow`` (the hub's 90 s row TTL).
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

    /// How fresh a heartbeat must be for the machine to show online: the hub's address-book row TTL
    /// (cmux-platform `src/server/mesh/Core.ts`, 90 s; the daemon heartbeats every 30 s or sooner).
    public static let onlineWindow: TimeInterval = 90

    /// Its state from its own heartbeat at `now`: revoked first (the platform's `revoked`, or the CLI's
    /// `state: "revoked"`, which keeps the last heartbeat); then online when `heartbeat` is within
    /// ``onlineWindow`` (a clock a little ahead counts as now); with no readable heartbeat, the CLI's word.
    static func state(revoked: Bool, heartbeat: Date?, listed: State?, now: Date) -> State {
        if revoked || listed == .revoked { return .revoked }
        guard let heartbeat else { return listed ?? .offline }
        return now.timeIntervalSince(heartbeat) <= onlineWindow ? .online : .offline
    }

    /// A heartbeat as the platform sends it: RFC 3339 text, or an epoch number (seconds below 1e11,
    /// else milliseconds, the CLI's own `epoch_ms` rule), as a number or a digits-only string.
    static func heartbeat(_ value: Any?) -> Date? {
        let number: Double? = if let n = value as? NSNumber, !(value is Bool) { n.doubleValue }
            else if let text = value as? String, !text.isEmpty, text.allSatisfy(\.isNumber) { Double(text) } else { nil }
        if let number { return Date(timeIntervalSince1970: number < 100_000_000_000 ? number : number / 1000) }
        return JoinLine.date(value)
    }

    /// The Machines section's id of a joined machine (its row, its last check in ``MachineHealthStore``).
    public static func healthID(_ id: String) -> String { "joined:\(id)" }

    /// The joined rows of `cmux machine list --json` (a JSON array of rows of every kind); nil when
    /// the output is not that array. Rows of other kinds, and joined rows with no id, are skipped.
    /// Each row's state is read from its heartbeat at `now` (``state(revoked:heartbeat:listed:now:)``).
    public static func list(from data: Data, now: Date = Date()) -> [JoinedMachine]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.compactMap { JoinedMachine(row: $0, now: now) }
    }

    init?(row: [String: Any], now: Date = Date()) {
        guard row["kind"] as? String == "joined" else { return nil }
        let text = { (key: String) -> String? in (row[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        guard let id = text("id") ?? text("machineId") else { return nil }
        let revoked = row["revoked"] as? Bool == true
        let state = Self.state(revoked: revoked, heartbeat: Self.heartbeat(row["lastHeartbeat"]),
                               listed: text("state").flatMap(State.init(rawValue:)), now: now)
        let shownHeartbeat = text("lastHeartbeat") ?? (row["lastHeartbeat"] as? NSNumber).map { "\($0)" }
        self.init(id: id, name: text("name") ?? text("label") ?? text("hostname") ?? id, state: state, lastHeartbeat: shownHeartbeat,
                  platform: text("platform"), hostname: text("hostname"), meshPeerId: text("meshPeerId"),
                  joinTokenId: text("joinTokenId"), mintedBy: text("mintedBy"))
    }
}
