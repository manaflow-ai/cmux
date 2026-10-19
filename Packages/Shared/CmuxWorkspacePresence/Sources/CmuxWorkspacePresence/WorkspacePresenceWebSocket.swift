import CMUXMobileCore
import Foundation

/// URLSession transport for the workspace-only presence protocol.
public struct WorkspacePresenceWebSocket: WorkspacePresenceConnecting {
    private let baseURL: URL

    /// Creates a transport for the deployment matching the app's auth environment.
    /// - Parameter baseURL: Service origin; loopback HTTP is accepted for local proof.
    public init(baseURL: URL) { self.baseURL = baseURL }

    public func connect(scope: WorkspacePresenceScope, accessToken: String) async throws -> any WorkspacePresenceConnection {
        let request = try request(scope: scope, accessToken: accessToken)
        return WorkspacePresenceSocket(request: request)
    }

    /// Builds a bounded, credentialed upgrade request.
    /// - Parameters:
    ///   - scope: Workspace identity forwarded by its host.
    ///   - accessToken: Stack credential carried only in Authorization.
    /// - Returns: The upgrade request.
    /// - Throws: URLError for an unsupported origin or invalid scope encoding.
    public func request(scope: WorkspacePresenceScope, accessToken: String) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil else { throw URLError(.badURL) }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http" where ["localhost", "127.0.0.1", "::1"].contains(components.host ?? ""):
            components.scheme = "ws"
        default: throw URLError(.badURL)
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + (components.path.isEmpty ? "" : components.path + "/") + "v1/workspace-presence"
        components.queryItems = [URLQueryItem(name: "scope", value: String(decoding: try JSONEncoder().encode(scope), as: UTF8.self))]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}
