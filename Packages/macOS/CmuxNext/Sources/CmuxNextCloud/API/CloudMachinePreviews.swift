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

    /// Keep the bootstrap credential intact while asking its server to open a path on the preview
    /// (cmux-cloud-machine `preview::browser_url`). The server validates `return_to` as a relative path.
    public func browserURL(path: String = "/") throws -> URL {
        struct Request: Encodable { var url: String, path: String }
        struct Reply: Decodable { var url: String? }
        guard let text = CloudMachineRules().call("cloud_model_preview_url", Request(url: url, path: path), as: Reply.self)?.url,
              let result = URL(string: text) else { throw CloudAPIError.decoding("machine.preview_invalid_url") }
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

extension CloudDaemon {
    /// Preview ingress lives at cmux-platform, while the existing guest API keeps its Worker. Same person,
    /// team and daemon as this one (its calls are the daemon's `cloud.previews.*` and `cloud.vm.*`).
    public func previewClient(baseURL: URL) -> CloudDaemon {
        var client = CloudDaemon(baseURL: baseURL, tokens: tokens, teamID: teamID, appVersion: appVersion, sendsStackSession: false,
                                 buildSpace: buildSpace)
        client.machineIO = machineIO
        client.daemonCall = daemonCall
        return client
    }

    // cmux-platform's previews (docs/cloud-previews.md) on a preview client (``previewClient(baseURL:)``), sent by the
    // daemon (cmux-cloud-api `previews.rs`): a publication is one machine port's preview, `vm_…:port`. The sign-in
    // client answers 501 and sends nothing.

    /// The daemon's `cloud.vm.domains`: the domains Cloud publications are served on (the platform's managed one).
    public func listDomains() async throws -> [CloudDomain] {
        try await previewCall("vm.domains", [:], as: [CloudDomain].self)
    }

    /// The daemon's `cloud.vm.publications`: the signed-in person's publications in the current team.
    public func listPublications() async throws -> [CloudPublication] {
        try await previewCall("vm.publications", [:], as: [CloudPublication].self)
    }

    /// The daemon's `cloud.vm.provision_api`: publishes `port` of the machine behind cmux sign-in (a refresh,
    /// when it has no preview yet) and mints an API key for it in one call. Calling it again for the same
    /// port reuses the publication and mints another key.
    public func provisionAPI(machineID: String, port: Int, keyName: String? = nil) async throws -> CloudProvisionedAPI {
        var args: [String: any Sendable] = ["machine": machineID, "port": port]
        if let keyName { args["keyName"] = keyName }
        return try await previewCall("vm.provision_api", args, timeout: .seconds(125), as: CloudProvisionedAPI.self)
    }

    /// The daemon's `cloud.vm.publication_api_keys`: the live API keys of a publication, named by its id or
    /// hostname (the daemon resolves it from the publication list, so two bounded requests).
    public func listPublicationAPIKeys(_ publication: String) async throws -> [CloudPublicationAPIKey] {
        try await previewCall("vm.publication_api_keys", ["publication": publication], timeout: .seconds(65),
                              as: [CloudPublicationAPIKey].self)
    }

    /// The daemon's `cloud.vm.revoke_publication_api_key`: revokes one key; its next request is refused at the edge.
    public func revokePublicationAPIKey(_ publication: String, keyID: String) async throws -> CloudPublicationAPIKey {
        try await previewCall("vm.revoke_publication_api_key", ["publication": publication, "keyId": keyID],
                              timeout: .seconds(65), as: CloudPublicationAPIKey.self)
    }

    /// One preview or publication call through the daemon, its body decoded as `type`. The daemon bounds
    /// each request at 30 s (120 s for a key's create); `timeout` bounds the child a little past that.
    func previewCall<T: Decodable>(_ call: String, _ args: [String: any Sendable], timeout: Duration = .seconds(35),
                                   as type: T.Type) async throws -> T {
        try requireWorker(code: "machine.previews_unsupported")
        let data = try await daemon(call, args, timeout: timeout)
        return try CloudMachineRules().answer(data, as: T.self, context: "cloud.\(call)")
    }

    /// New Cloud only: the daemon's `cloud.previews.refresh` discovers current listeners and reconciles
    /// their private preview routes.
    public func refreshPreviews(_ id: String) async throws -> CloudMachinePreviews {
        try await previewCall("previews.refresh", ["machine": id], as: CloudMachinePreviews.self)
    }

    /// The daemon's `cloud.previews.create_link`: a one-day anonymous preview link by default. The
    /// platform caps custom expiries at seven days and validates the port and ownership.
    public func createPreviewShareLink(_ id: String, port: Int, expiresAt: Int? = nil, maxUses: Int? = nil) async throws -> CloudPreviewShareLinkCreated {
        var args: [String: any Sendable] = ["machine": id, "port": port]
        if let expiresAt { args["expiresAt"] = expiresAt }
        if let maxUses { args["maxUses"] = maxUses }
        return try await previewCall("previews.create_link", args, as: CloudPreviewShareLinkCreated.self)
    }

    /// The daemon's `cloud.previews.revoke_link`: revokes one anonymous preview link. Existing
    /// preview cookies are rejected by the platform on their next request.
    public func revokePreviewShareLink(_ id: String, port: Int, linkID: String) async throws -> CloudPreviewShareLinkRevocation {
        try await previewCall("previews.revoke_link", ["machine": id, "port": port, "linkId": linkID],
                              as: CloudPreviewShareLinkRevocation.self)
    }
}
