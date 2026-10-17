public import Foundation

/// One Cloud machine as `/api/vm` reports it. The machine id is the
/// provider VM id (`vm-…`).
public struct CloudMachine: Sendable, Hashable, Identifiable, Decodable {
    public enum Status: String, Sendable, Hashable, Decodable {
        case provisioning, running, failed, paused, destroyed, unknown

        public init(from decoder: any Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// A machine whose daemon can be reached (or soon will be).
        public var isLive: Bool { self == .running || self == .provisioning }
    }

    public struct Address: Sendable, Hashable, Decodable {
        public var ipv4: String?
        public var ipv6: String?
    }

    public struct Size: Sendable, Hashable, Decodable {
        public var name: String?
        public var cpu: Int?
        public var memoryMb: Int?
        public var storageMb: Int?
    }

    /// Provider operations and session transports advertised for this machine.
    public struct Capabilities: Sendable, Hashable, Decodable {
        public var snapshot: Bool
        public var restore: Bool
        public var fork: Bool
        public var exec: Bool
        public var stats: Bool
        public var restart: Bool
        public var ports: Bool
        public var desktop: Bool
        public var sizing: Bool
        public var persistentHome: Bool
        public var attachTransports: [String]

        /// Creates a conservative capability set for an older or incomplete response.
        public init(snapshot: Bool = false, restore: Bool = false, fork: Bool = false,
                    exec: Bool = false, stats: Bool = false, restart: Bool = false,
                    ports: Bool = false, desktop: Bool = false, sizing: Bool = false,
                    persistentHome: Bool = false, attachTransports: [String] = []) {
            self.snapshot = snapshot
            self.restore = restore
            self.fork = fork
            self.exec = exec
            self.stats = stats
            self.restart = restart
            self.ports = ports
            self.desktop = desktop
            self.sizing = sizing
            self.persistentHome = persistentHome
            self.attachTransports = attachTransports
        }

        private enum CodingKeys: String, CodingKey {
            case snapshot, restore, fork, exec, stats, restart, ports, desktop, sizing, persistentHome, attachTransports
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(snapshot: try c.decodeIfPresent(Bool.self, forKey: .snapshot) ?? false,
                      restore: try c.decodeIfPresent(Bool.self, forKey: .restore) ?? false,
                      fork: try c.decodeIfPresent(Bool.self, forKey: .fork) ?? false,
                      exec: try c.decodeIfPresent(Bool.self, forKey: .exec) ?? false,
                      stats: try c.decodeIfPresent(Bool.self, forKey: .stats) ?? false,
                      restart: try c.decodeIfPresent(Bool.self, forKey: .restart) ?? false,
                      ports: try c.decodeIfPresent(Bool.self, forKey: .ports) ?? false,
                      desktop: try c.decodeIfPresent(Bool.self, forKey: .desktop) ?? false,
                      sizing: try c.decodeIfPresent(Bool.self, forKey: .sizing) ?? false,
                      persistentHome: try c.decodeIfPresent(Bool.self, forKey: .persistentHome) ?? false,
                      attachTransports: try c.decodeIfPresent([String].self, forKey: .attachTransports) ?? [])
        }
    }

    public var id: String
    public var provider: String
    public var status: Status
    public var displayName: String?
    public var slug: String?
    public var kind: String?
    public var image: String?
    public var imageVersion: String?
    public var createdAt: Date?
    public var address: Address?
    public var size: Size?
    /// Server-declared provider operations and attach transports.
    public var capabilities: Capabilities

    /// Sidebar and menu title: the user's name, else the slug, else the id.
    public var title: String { displayName?.nonEmpty ?? slug?.nonEmpty ?? id }

    enum CodingKeys: String, CodingKey {
        case id, provider, status, displayName, slug, kind, image, imageVersion, createdAt, address, size, capabilities
    }

    public init(id: String, provider: String = "freestyle", status: Status = .running, displayName: String? = nil,
                slug: String? = nil, address: Address? = nil, capabilities: Capabilities = .init()) {
        self.id = id
        self.provider = provider
        self.status = status
        self.displayName = displayName
        self.slug = slug
        self.address = address
        self.capabilities = capabilities
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        // A create response carries no status; the machine is coming up.
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .provisioning
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        imageVersion = try c.decodeIfPresent(String.self, forKey: .imageVersion)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt).map { Date(timeIntervalSince1970: $0 / 1000) }
        address = try c.decodeIfPresent(Address.self, forKey: .address)
        size = try c.decodeIfPresent(Size.self, forKey: .size)
        capabilities = try c.decodeIfPresent(Capabilities.self, forKey: .capabilities) ?? .init()
    }
}

/// `POST /api/vm/{id}/attach-endpoint {transport:"cmux-remote"}`.
public struct CloudAttachEndpoint: Sendable, Hashable, Decodable {
    public var transport: String
    public var route: String
    public var session: String
    public var trustedCarrier: Bool
    public var expiresAtUnix: Double?
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
