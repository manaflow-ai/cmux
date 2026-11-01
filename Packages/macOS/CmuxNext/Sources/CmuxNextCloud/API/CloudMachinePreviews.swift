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
}
