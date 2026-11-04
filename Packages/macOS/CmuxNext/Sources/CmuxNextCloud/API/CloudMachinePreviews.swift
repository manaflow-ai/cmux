public import Foundation

/// The platform's detected TCP listeners and their authenticated browser previews.
public struct CloudMachinePreviews: Decodable, Sendable, Equatable {
    public var machine: String
    public var previews: [CloudMachinePreview]
    public var listening: [Int]
    public var unavailable: [CloudMachinePreviewUnavailable]
}

public struct CloudMachinePreview: Decodable, Sendable, Equatable {
    public var port: Int
    /// A short-lived authentication bootstrap URL; open this rather than the bare origin.
    public var url: String
    public var origin: String
    /// Unix milliseconds, as reported by the platform.
    public var expiresAt: Double

    /// Keep the bootstrap credential intact while asking its server to open a path on the preview.
    /// The server validates `return_to` as a relative path before redirecting.
    public func browserURL(path: String = "/") throws -> URL {
        guard var components = URLComponents(string: url), components.scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else {
            throw CloudAPIError.decoding("machine.preview_invalid_url")
        }
        if path != "/" {
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "return_to" }
            items.append(URLQueryItem(name: "return_to", value: path))
            components.queryItems = items
        }
        guard let result = components.url else { throw CloudAPIError.decoding("machine.preview_invalid_url") }
        return result
    }
}

public struct CloudMachinePreviewUnavailable: Decodable, Sendable, Equatable {
    public var port: Int
    public var code: String
}

/// One anonymous, expiring link to a live preview. The platform only returns
/// the secret URL when a link is created; list responses contain this metadata
/// without the secret.
public struct CloudPreviewShareLink: Decodable, Sendable, Equatable {
    public var linkId: String
    public var creator: String
    public var team: String
    public var machine: String
    public var port: Int
    public var hostname: String
    public var ruleId: String
    public var createdAt: Int
    public var expiresAt: Int
    public var maxUses: Int?
    public var redemptions: Int
    public var revokedAt: Int?
}

public struct CloudPreviewShareLinkCreated: Decodable, Sendable, Equatable {
    public var link: CloudPreviewShareLink
    public var url: String
}

public struct CloudPreviewShareLinkRevocation: Decodable, Sendable, Equatable {
    public var revoked: Bool
}

extension CloudAPIClient {
    /// Preview ingress lives at cmux-platform, while the existing guest API keeps its Worker.
    public func previewClient(baseURL: URL) -> CloudAPIClient {
        CloudAPIClient(baseURL: baseURL, tokens: tokens, teamID: teamID, session: session, appVersion: appVersion)
    }

    /// New Cloud only: discovers current listeners and reconciles their private preview routes.
    public func refreshPreviews(_ id: String) async throws -> CloudMachinePreviews {
        guard !sendsStackSession else {
            throw CloudAPIError.http(status: 501, code: "machine.previews_unsupported", message: nil)
        }
        return try await send("POST", "\(machinePath)/\(id)/previews/refresh", timeout: .seconds(30), as: CloudMachinePreviews.self)
    }

    /// Creates a one-day anonymous preview link by default. The platform caps
    /// custom expiries at seven days and validates the port and ownership.
    public func createPreviewShareLink(_ id: String, port: Int, expiresAt: Int? = nil, maxUses: Int? = nil) async throws -> CloudPreviewShareLinkCreated {
        var body: [String: any Sendable] = [:]
        if let expiresAt { body["expiresAt"] = expiresAt }
        if let maxUses { body["maxUses"] = maxUses }
        return try await send("POST", "\(machinePath)/\(id)/previews/\(port)/links", body: body,
                              timeout: .seconds(30), as: CloudPreviewShareLinkCreated.self)
    }

    /// Revokes one anonymous preview link. Existing preview cookies are
    /// rejected by the platform on their next request.
    public func revokePreviewShareLink(_ id: String, port: Int, linkID: String) async throws -> CloudPreviewShareLinkRevocation {
        try await send("DELETE", "\(machinePath)/\(id)/previews/\(port)/links/\(linkID)",
                       timeout: .seconds(30), as: CloudPreviewShareLinkRevocation.self)
    }
}
