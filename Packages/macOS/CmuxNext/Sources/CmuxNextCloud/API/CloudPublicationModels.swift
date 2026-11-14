import Foundation

/// A domain Cloud publications are served on (cmux-platform's `GET /v1/cloud/domains`).
public struct CloudDomain: Sendable, Hashable, Codable {
    public var id: String?
    public var hostname: String?
    public var verificationState: String?
    public var certificateState: String?
    public var createdAt: String?
    public var publications: [CloudDomainPublication]?
}

/// The publication summary nested in a custom-domain response.
public struct CloudDomainPublication: Sendable, Hashable, Codable {
    public var id: String?
    public var hostname: String?
    public var state: String?
}

/// A Cloud publication: one machine port's preview (cmux-platform's `GET /v1/cloud/previews`).
/// Provider and certificate details stay server-side.
public struct CloudPublication: Sendable, Hashable, Codable {
    public var id: String?
    public var hostname: String?
    public var url: String?
    public var domainKind: String?
    public var vmId: String?
    public var port: Int?
    public var publicPort: Int?
    public var targetPort: Int?
    public var protocolName: String?
    public var accessMode: String?
    public var teamId: String?
    public var state: String?
    public var routingRevision: Int?
    public var verification: CloudPublicationVerification?

    private enum CodingKeys: String, CodingKey {
        case id, hostname, url, domainKind, vmId, port, publicPort, targetPort
        case protocolName = "protocol"
        case accessMode, teamId, state, routingRevision, verification
    }
}
