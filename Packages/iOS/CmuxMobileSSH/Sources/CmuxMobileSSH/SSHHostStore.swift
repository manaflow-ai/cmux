import Foundation

/// Legacy: the single persistence mode a host used before Round 3 (PRD D31).
/// A host now serves cmux-tui workspaces, tmux sessions, and plain shells
/// side by side, so nothing reads this; it stays so saved hosts decode.
public enum SSHPersistenceMode: String, Codable, CaseIterable, Sendable {
    /// cmux-tui session on the server, uploaded by the phone (recommended).
    case cmuxTUI
    /// A named tmux session, if tmux is installed.
    case tmux
    /// A plain login shell that ends with the connection.
    case plain
    /// Eternal Terminal (v1.1, coming soon).
    case eternalTerminal
    /// mosh (v1.2, coming soon).
    case mosh

    /// Modes that can be chosen in v1.
    public var isAvailable: Bool {
        switch self {
        case .cmuxTUI, .tmux, .plain: true
        case .eternalTerminal, .mosh: false
        }
    }
}

/// How long a detached session may idle before the server closes it (PRD D13).
public enum SSHIdleClosePolicy: String, Codable, CaseIterable, Sendable {
    case oneHour, oneDay, sevenDays, never

    public var seconds: Int? {
        switch self {
        case .oneHour: 3_600
        case .oneDay: 86_400
        case .sevenDays: 604_800
        case .never: nil
        }
    }
}

/// A user-added SSH computer. Stored on this device only (PRD D5).
public struct SSHHostRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var endpoint: SSHEndpoint
    /// Key used to log in; `nil` until the user picks one.
    public var keyID: UUID?
    /// Another saved host to tunnel through (ProxyJump).
    public var jumpHostID: UUID?
    /// Legacy (PRD D31): the mode picked before hosts served every kind at
    /// once. Decoded so hosts saved by older builds load; ignored otherwise.
    public var persistence: SSHPersistenceMode?
    public var idleClose: SSHIdleClosePolicy
    public var createdAt: Date
    /// `true` after the user declined this host's identity question: the
    /// app stops connecting on its own (also after relaunch) until the user
    /// connects explicitly. Optional so hosts saved before it existed decode.
    public var autoConnectPaused: Bool?

    /// Whether automatic reconnects are paused for this host.
    public var isAutoConnectPaused: Bool { autoConnectPaused ?? false }

    /// Whether `other` reaches the same server the same way: address, port,
    /// user, key, and jump host. Name, idle policy, and pause state do not
    /// change how the host connects.
    public func connectsLike(_ other: SSHHostRecord) -> Bool {
        id == other.id && endpoint == other.endpoint && keyID == other.keyID && jumpHostID == other.jumpHostID
    }

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: SSHEndpoint,
        keyID: UUID? = nil,
        jumpHostID: UUID? = nil,
        persistence: SSHPersistenceMode? = nil,
        idleClose: SSHIdleClosePolicy = .oneDay,
        createdAt: Date = Date(),
        autoConnectPaused: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.keyID = keyID
        self.jumpHostID = jumpHostID
        self.persistence = persistence
        self.idleClose = idleClose
        self.createdAt = createdAt
        self.autoConnectPaused = autoConnectPaused
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, keyID, jumpHostID, persistence, idleClose, createdAt, autoConnectPaused
    }

    /// Lenient about fields nothing reads anymore: an unreadable legacy
    /// `persistence` (or a missing `idleClose`) must not drop the host,
    /// since one bad record fails the whole saved list.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        endpoint = try container.decode(SSHEndpoint.self, forKey: .endpoint)
        keyID = try container.decodeIfPresent(UUID.self, forKey: .keyID)
        jumpHostID = try container.decodeIfPresent(UUID.self, forKey: .jumpHostID)
        persistence = try? container.decodeIfPresent(SSHPersistenceMode.self, forKey: .persistence)
        idleClose = (try? container.decodeIfPresent(SSHIdleClosePolicy.self, forKey: .idleClose)) ?? .oneDay
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        autoConnectPaused = try container.decodeIfPresent(Bool.self, forKey: .autoConnectPaused)
    }
}

/// Saved hosts and pinned host keys, persisted as JSON in the app's support
/// directory. Neither is secret; keys live in ``SSHKeyStore``.
public actor SSHHostStore: SSHKnownHostsStore {
    private let hostsURL: URL
    private let knownHostsURL: URL
    private let lastUsedURL: URL
    private var hosts: [SSHHostRecord]
    private var knownHosts: [String: SSHHostKey]
    private var lastUsed: UUID?

    public init(directory: URL) {
        hostsURL = directory.appendingPathComponent("ssh-hosts.json")
        knownHostsURL = directory.appendingPathComponent("ssh-known-hosts.json")
        lastUsedURL = directory.appendingPathComponent("ssh-last-used-host.json")
        hosts = (try? JSONDecoder().decode([SSHHostRecord].self, from: Data(contentsOf: hostsURL))) ?? []
        knownHosts = (try? JSONDecoder().decode([String: SSHHostKey].self, from: Data(contentsOf: knownHostsURL))) ?? [:]
        lastUsed = try? JSONDecoder().decode(UUID.self, from: Data(contentsOf: lastUsedURL))
    }

    /// The saved host the user opened most recently, the SSH counterpart of
    /// a paired Mac's persisted active flag. `nil` when none was opened yet
    /// or it was deleted.
    public func lastUsedHostID() -> UUID? {
        guard let lastUsed, hosts.contains(where: { $0.id == lastUsed }) else { return nil }
        return lastUsed
    }

    /// Records that the user opened `id`. Unknown ids are ignored.
    public func markUsed(id: UUID) {
        guard lastUsed != id, hosts.contains(where: { $0.id == id }) else { return }
        lastUsed = id
        try? write(id, to: lastUsedURL)
    }

    public func all() -> [SSHHostRecord] { hosts.sorted { $0.createdAt < $1.createdAt } }

    public func host(id: UUID) -> SSHHostRecord? { hosts.first { $0.id == id } }

    public func upsert(_ host: SSHHostRecord) throws {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        try write(hosts, to: hostsURL)
    }

    public func delete(id: UUID) throws {
        hosts.removeAll { $0.id == id }
        if lastUsed == id {
            lastUsed = nil
            try? FileManager.default.removeItem(at: lastUsedURL)
        }
        for index in hosts.indices where hosts[index].jumpHostID == id {
            hosts[index].jumpHostID = nil
        }
        try write(hosts, to: hostsURL)
    }

    // MARK: SSHKnownHostsStore

    public func pinnedKey(for identity: String) -> SSHHostKey? { knownHosts[identity] }

    public func pin(_ key: SSHHostKey, for identity: String) {
        knownHosts[identity] = key
        try? write(knownHosts, to: knownHostsURL)
    }

    public func forget(identity: String) {
        knownHosts[identity] = nil
        try? write(knownHosts, to: knownHostsURL)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
