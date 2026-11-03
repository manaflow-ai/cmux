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

/// A share URL, without the owner's private preview bootstrap credential.
public struct CloudMachinePreviewShare: Decodable, Sendable, Equatable {
    public var url: String
    public init(url: String) { self.url = url }
}

public struct CloudMachinePreviewUnavailable: Decodable, Sendable, Equatable {
    public var port: Int
    public var code: String
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
        let inventory = try await send("POST", "\(machinePath)/\(pathSegment(id))/previews/refresh", timeout: .seconds(30), as: CloudMachinePreviews.self)
        guard inventory.machine == id else { throw CloudAPIError.decoding("machine.preview_wrong_machine") }
        return inventory
    }
}

extension CloudAPIClient {
    /// Thin account-session adapter to the same endpoints used by the guest agent.
    public func sharePreview(_ id: String, port: Int, audience: String, userID: String? = nil) async throws -> CloudMachinePreviewShare {
        guard (1...65535).contains(port), ["link", "team", "user"].contains(audience) else {
            throw CloudAPIError.decoding("machine.preview_invalid_share")
        }
        let current = try await refreshPreviews(id)
        guard current.machine == id, let preview = current.previews.first(where: { $0.port == port }) else {
            throw CloudAPIError.decoding("machine.preview_not_listening")
        }
        let path = "\(machinePath)/\(pathSegment(id))/previews/\(port)"
        if audience == "link" {
            let shared = try await send("POST", "\(path)/links", body: [:], as: CloudMachinePreviewShare.self)
            _ = try CloudMachinePreview(port: port, url: shared.url, origin: preview.origin, expiresAt: 0).browserURL()
            return shared
        }
        let recipient: String
        if audience == "team", let team = await teamID(), !team.isEmpty {
            recipient = team
        } else if audience == "user", let userID, !userID.isEmpty {
            recipient = userID
        } else {
            throw CloudAPIError.decoding("machine.preview_invalid_share")
        }
        _ = try await send("PUT", "\(path)/grants", body: ["kind": audience, "id": recipient], as: Ignored.self)
        // Recipients authenticate with their own session; never copy the owner's token.
        _ = try CloudMachinePreview(port: port, url: preview.origin, origin: preview.origin, expiresAt: 0).browserURL()
        return CloudMachinePreviewShare(url: preview.origin)
    }
}
