import Foundation

/// A custom domain owned by the signed-in Cloud account.
public struct CloudDomain: Sendable, Hashable, Decodable {
    public var id: String?
    public var hostname: String?
    public var verificationState: String?
    public var certificateState: String?
    public var createdAt: String?
    public var publications: [CloudDomainPublication]?
}

/// The publication summary nested in a custom-domain response.
public struct CloudDomainPublication: Sendable, Hashable, Decodable {
    public var id: String?
    public var hostname: String?
    public var state: String?
}

/// A Cloud VM publication. Provider and certificate details stay server-side;
/// the UI receives only the redacted publication view.
public struct CloudPublication: Sendable, Hashable, Decodable {
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

/// Verification is intentionally kept to its state. DNS records and provider
/// details remain server-side and are not surfaced by the read action.
public struct CloudPublicationVerification: Sendable, Hashable, Decodable {
    public var verificationId: String?
    public var domain: String?
    public var state: String?
}
