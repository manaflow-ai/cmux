import Foundation

/// How a host keeps shells alive across disconnects (PRD D9, D15).
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
    /// `nil` until the user answers the first-connect persistence question.
    public var persistence: SSHPersistenceMode?
    public var idleClose: SSHIdleClosePolicy
    public var createdAt: Date
    /// `true` after the user declined this host's identity question: the
    /// app stops connecting on its own (also after relaunch) until the user
    /// connects explicitly. Optional so hosts saved before it existed decode.
    public var autoConnectPaused: Bool?

    /// Whether automatic reconnects are paused for this host.
    public var isAutoConnectPaused: Bool { autoConnectPaused ?? false }

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
}

/// Saved hosts and pinned host keys, persisted as JSON in the app's support
/// directory. Neither is secret; keys live in ``SSHKeyStore``.
public actor SSHHostStore: SSHKnownHostsStore {
    private let hostsURL: URL
    private let knownHostsURL: URL
    private var hosts: [SSHHostRecord]
    private var knownHosts: [String: SSHHostKey]

    public init(directory: URL) {
        hostsURL = directory.appendingPathComponent("ssh-hosts.json")
        knownHostsURL = directory.appendingPathComponent("ssh-known-hosts.json")
        hosts = (try? JSONDecoder().decode([SSHHostRecord].self, from: Data(contentsOf: hostsURL))) ?? []
        knownHosts = (try? JSONDecoder().decode([String: SSHHostKey].self, from: Data(contentsOf: knownHostsURL))) ?? [:]
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
