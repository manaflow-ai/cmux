import Foundation

public struct MacfleetManifest: Decodable, Equatable, Sendable {
    public var defaultPassword: String?
    public var hosts: [MacfleetHost]

    public init(defaultPassword: String? = nil, hosts: [MacfleetHost]) {
        self.defaultPassword = defaultPassword
        self.hosts = hosts
    }

    enum CodingKeys: String, CodingKey {
        case defaultPassword = "default_password"
        case hosts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultPassword = try container.decodeIfPresent(String.self, forKey: .defaultPassword)
        hosts = try container.decodeIfPresent([MacfleetHost].self, forKey: .hosts) ?? []
    }

    public static func load(from url: URL) throws -> MacfleetManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MacfleetManifest.self, from: data)
    }

    public func expandedSessions(
        matchingTag tag: String? = "tag:mac-mini-cluster"
    ) -> [MacfleetVNCSession] {
        hosts.flatMap { host in
            host.expandedSessions(defaultPassword: defaultPassword, matchingTag: tag)
        }
    }
}

public struct MacfleetHost: Decodable, Equatable, Sendable {
    public var name: String
    public var ssh: String?
    public var prefix: String
    public var sessions: MacfleetSessionSpec
    public var tag: String?
    public var password: String?
    public var defaultPassword: String?

    public init(
        name: String,
        ssh: String? = nil,
        prefix: String,
        sessions: MacfleetSessionSpec,
        tag: String? = nil,
        password: String? = nil,
        defaultPassword: String? = nil
    ) {
        self.name = name
        self.ssh = ssh
        self.prefix = prefix
        self.sessions = sessions
        self.tag = tag
        self.password = password
        self.defaultPassword = defaultPassword
    }

    enum CodingKeys: String, CodingKey {
        case name
        case ssh
        case prefix
        case sessions
        case tag
        case password
        case defaultPassword = "default_password"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        ssh = try container.decodeIfPresent(String.self, forKey: .ssh)
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? name
        sessions = try container.decode(MacfleetSessionSpec.self, forKey: .sessions)
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        defaultPassword = try container.decodeIfPresent(String.self, forKey: .defaultPassword)
    }

    public func expandedSessions(
        defaultPassword manifestDefaultPassword: String?,
        matchingTag requestedTag: String?
    ) -> [MacfleetVNCSession] {
        if let requestedTag, tag != requestedTag {
            return []
        }

        let hostDefaultPassword = password ?? defaultPassword ?? manifestDefaultPassword
        switch sessions {
        case .count(let count):
            guard count > 0 else { return [] }
            return (1...count).map { index in
                MacfleetVNCSession(
                    name: "\(prefix)-\(index)",
                    hostName: name,
                    address: "\(prefix)-\(index)",
                    port: 5900,
                    username: Self.defaultUsername(for: index),
                    sessionPassword: password,
                    defaultPassword: defaultPassword ?? manifestDefaultPassword,
                    tag: tag,
                    index: index
                )
            }
        case .sessions(let sessionConfigs):
            return sessionConfigs.enumerated().map { offset, config in
                let index = config.index ?? offset + 1
                let sessionName = config.name ?? "\(prefix)-\(index)"
                return MacfleetVNCSession(
                    name: sessionName,
                    hostName: name,
                    address: config.address ?? sessionName,
                    port: config.port ?? 5900,
                    username: config.username ?? Self.defaultUsername(for: index),
                    sessionPassword: config.password ?? password,
                    defaultPassword: config.defaultPassword ?? hostDefaultPassword,
                    tag: config.tag ?? tag,
                    index: index
                )
            }
        }
    }

    public static func defaultUsername(for index: Int) -> String {
        index <= 1 ? "cmuxvnc" : "cmuxvnc\(index)"
    }
}

public enum MacfleetSessionSpec: Decodable, Equatable, Sendable {
    case count(Int)
    case sessions([MacfleetSessionConfig])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let count = try? container.decode(Int.self) {
            self = .count(count)
            return
        }
        self = .sessions(try container.decode([MacfleetSessionConfig].self))
    }
}

public struct MacfleetSessionConfig: Decodable, Equatable, Sendable {
    public var index: Int?
    public var name: String?
    public var address: String?
    public var port: Int?
    public var username: String?
    public var password: String?
    public var defaultPassword: String?
    public var tag: String?

    enum CodingKeys: String, CodingKey {
        case index
        case name
        case address
        case host
        case port
        case username
        case password
        case defaultPassword = "default_password"
        case tag
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        address = try container.decodeIfPresent(String.self, forKey: .address)
            ?? container.decodeIfPresent(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        defaultPassword = try container.decodeIfPresent(String.self, forKey: .defaultPassword)
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
    }
}

public struct MacfleetVNCSession: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var hostName: String
    public var address: String
    public var port: Int
    public var username: String
    public var sessionPassword: String?
    public var defaultPassword: String?
    public var tag: String?
    public var index: Int

    public init(
        name: String,
        hostName: String,
        address: String,
        port: Int,
        username: String,
        sessionPassword: String? = nil,
        defaultPassword: String? = nil,
        tag: String? = nil,
        index: Int
    ) {
        self.name = name
        self.hostName = hostName
        self.address = address
        self.port = port
        self.username = username
        self.sessionPassword = sessionPassword
        self.defaultPassword = defaultPassword
        self.tag = tag
        self.index = index
    }

    public var workspaceTitle: String { name }
}
