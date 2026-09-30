import Foundation

/// SSH hosts the user entered, kept in the home daemon's personal state
/// (frontend projection `ssh-hosts`) until their first successful connect.
/// After it, the session registry (`put-session`, keyed by the remote
/// session id) is the only record and the entry is dropped. Entries hold
/// transport fields only (route, session, cmux-tui path), never a secret.
public struct SavedHostsDocument: Codable, Sendable, Hashable {
    public static let schemaVersion: UInt32 = 1
    /// Oldest entries are dropped past this many hosts.
    public static let limit = 64

    public struct Host: Codable, Sendable, Hashable {
        /// The app's machine id for the host (`SSHHost.machineID`).
        public var id: String
        /// The registry `transport` object (`SSHHost.transportFields` plus `connect`).
        public var transport: [String: String]
        public var addedMs: UInt64

        enum CodingKeys: String, CodingKey {
            case id, transport
            case addedMs = "added_ms"
        }
    }

    public var hosts: [Host]

    public init(hosts: [Host] = []) {
        self.hosts = hosts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = (try? c.decodeIfPresent([Host].self, forKey: .hosts)) ?? []
    }

    /// Replaces the host's transport (keeping its place and entry time) or
    /// appends it, dropping the oldest past ``limit``.
    public mutating func upsert(id: String, transport: [String: String], nowMs: UInt64) {
        if let index = hosts.firstIndex(where: { $0.id == id }) {
            hosts[index].transport = transport
        } else {
            hosts.append(Host(id: id, transport: transport, addedMs: nowMs))
            if hosts.count > Self.limit { hosts.removeFirst(hosts.count - Self.limit) }
        }
    }

    public mutating func remove(id: String) {
        hosts.removeAll { $0.id == id }
    }

    /// Hosts the session registry does not hold yet.
    public func pending(registered: Set<String>) -> [Host] {
        hosts.filter { !registered.contains($0.id) }
    }

    /// Drops hosts the session registry holds; true when any was dropped.
    public mutating func pruned(registered: Set<String>) -> Bool {
        let before = hosts.count
        hosts.removeAll { registered.contains($0.id) }
        return hosts.count != before
    }

    func jsonValue() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
    }

    init(jsonValue: JSONValue) throws {
        self = try JSONDecoder().decode(SavedHostsDocument.self, from: JSONEncoder().encode(jsonValue))
    }
}
