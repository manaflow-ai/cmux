import Foundation

/// One API key of a protected Cloud publication, as `/api/vm/publications/:id/api-keys`
/// lists it. The server never answers the key itself here, only its last four characters.
public struct CloudPublicationAPIKey: Sendable, Hashable, Decodable {
    public var id: String
    public var publicationId: String?
    public var name: String?
    public var hint: String?
    public var createdAt: String?
    public var expiresAt: String?
    public var revokedAt: String?
}

/// `POST /api/vm/apis`: a machine port published under a generated hostname, with a new key.
/// `token` is in this answer only; API clients send it as `cookie` (`__Host-cmux-api-key=<token>`),
/// which the Cloud edge withholds from the machine.
public struct CloudProvisionedAPI: Sendable, Hashable, Decodable {
    public var url: String
    public var publication: CloudPublication
    public var apiKey: CloudPublicationAPIKey
    public var token: String
    public var cookieName: String
    public var cookie: String

    /// String fields returned by the provision action to CLI, MCP and agent callers.
    /// Optional publication fields are omitted when the server does not supply them.
    public var actionFields: [String: String] {
        var fields = [
            "url": url, "api_key_id": apiKey.id, "key": token, "cookie": cookie,
        ]
        if let id = publication.id { fields["publication_id"] = id }
        if let access = publication.accessMode { fields["access"] = access }
        return fields
    }
}
