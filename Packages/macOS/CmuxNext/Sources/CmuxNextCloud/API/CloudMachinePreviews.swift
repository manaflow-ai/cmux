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
        var client = CloudAPIClient(baseURL: baseURL, tokens: tokens, teamID: teamID, session: session, appVersion: appVersion)
        client.machineIO = machineIO
        return client
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
    /// The native app forwards its account session to Rust's shared preview operation.
    public func sharePreview(_ id: String, port: Int, audience: String, userID: String? = nil) async throws -> CloudMachinePreviewShare {
        guard let machineIO else {
            throw CloudAPIError.http(status: 501, code: "machine.previews_unsupported", message: nil)
        }
        let access: String
        do { access = try await tokens().access } catch { throw CloudAPIError.notSignedIn }
        let recipient: any Sendable
        if audience == "user" { recipient = ["user": userID ?? ""] } else { recipient = audience }
        let request: [String: any Sendable] = [
            "api": baseURL.absoluteString, "credential": access, "team": await teamID() ?? "", "machine": id,
            "ask": ["operation": "share", "port": port, "audience": recipient, "bootstrap": false] as [String: any Sendable],
            "app_version": appVersion,
        ]
        return try await machineIO.preview(request)
    }
}
