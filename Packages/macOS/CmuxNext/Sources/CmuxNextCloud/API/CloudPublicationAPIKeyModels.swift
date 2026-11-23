import Foundation

/// One API key of a Cloud publication (a machine port's preview), as cmux-platform's
/// `/v1/cloud/machines/{id}/previews/{port}/api-keys` lists it. The server never answers the key itself here, only its last four characters.
public struct CloudPublicationAPIKey: Sendable, Hashable, Codable {
    public var id: String
    public var publicationId: String?
    public var name: String?
    public var hint: String?
    public var createdAt: String?
    public var expiresAt: String?
    public var revokedAt: String?
}

/// `POST /v1/cloud/machines/{id}/previews/{port}/api-keys`: a machine port's preview, with a new key.
/// `token` is in this answer only; API clients send it as `cookie` (`__Host-cmux-preview=<token>`),
/// which the Cloud edge withholds from the machine.
public struct CloudProvisionedAPI: Sendable, Hashable, Codable {
    public var url: String
    public var publication: CloudPublication
    public var apiKey: CloudPublicationAPIKey
    public var token: String
    public var cookieName: String
    public var cookie: String

    /// String fields returned by the provision action to CLI, MCP and agent callers
    /// (cmux-cloud-machine `models::provisioned_api_fields`).
    public var actionFields: [String: String] {
        struct Request: Encodable { var api: CloudProvisionedAPI }
        struct Reply: Decodable { var fields: [String: String] }
        return CloudMachineRules().call("cloud_model_provisioned_api_fields", Request(api: self), as: Reply.self)?.fields ?? ["url": url]
    }
}
