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

    /// Sidebar and menu title: the user's name, else the slug, else the id.
    public var title: String { displayName?.nonEmpty ?? slug?.nonEmpty ?? id }

    enum CodingKeys: String, CodingKey {
        case id, provider, status, displayName, slug, kind, image, imageVersion, createdAt, address, size
    }

    public init(id: String, provider: String = "freestyle", status: Status = .running, displayName: String? = nil,
                slug: String? = nil, address: Address? = nil) {
        self.id = id
        self.provider = provider
        self.status = status
        self.displayName = displayName
        self.slug = slug
        self.address = address
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
