public import Foundation

/// Creates and ends authenticated workspace-share rooms over HTTPS.
public struct WorkspaceShareAPIClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    /// Creates a room API client.
    /// - Parameters:
    ///   - baseURL: Worker origin, without a path.
    ///   - session: URL session used for requests.
    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Creates one short-lived room for a fixed workspace.
    /// - Parameters:
    ///   - workspaceID: App-session workspace identifier.
    ///   - workspaceTitle: Display-safe title shown after approval.
    ///   - accessToken: Current Stack access token.
    /// - Returns: Room endpoints and the host capability.
    public func create(
        workspaceID: UUID,
        workspaceTitle: String,
        accessToken: String
    ) async throws -> WorkspaceShareSession {
        var request = URLRequest(url: try endpoint(path: "v1/shares"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(CreateRequest(
            workspaceId: workspaceID.uuidString,
            workspaceTitle: workspaceTitle
        ))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkspaceShareError.invalidResponse }
        if http.statusCode == 401 { throw WorkspaceShareError.unauthorized }
        guard http.statusCode == 201 else { throw WorkspaceShareError.unavailable }
        do {
            return try JSONDecoder().decode(WorkspaceShareSession.self, from: data)
        } catch {
            throw WorkspaceShareError.invalidResponse
        }
    }

    /// Ends one room and revokes every connected viewer.
    /// - Parameters:
    ///   - sessionInfo: Room being ended.
    ///   - accessToken: Current Stack access token.
    public func end(
        _ sessionInfo: WorkspaceShareSession,
        accessToken: String
    ) async throws {
        var request = URLRequest(url: try endpoint(path: "v1/shares/\(sessionInfo.shareId)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionInfo.hostCapability, forHTTPHeaderField: "X-Cmux-Share-Capability")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WorkspaceShareError.unavailable
        }
    }

    private func endpoint(path: String) throws -> URL {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && baseURL.host?.isLoopbackHost == true),
              baseURL.path.isEmpty || baseURL.path == "/" else {
            throw WorkspaceShareError.invalidServiceURL
        }
        return baseURL.appendingPathComponent(path)
    }
}

private struct CreateRequest: Encodable, Sendable {
    let workspaceId: String
    let workspaceTitle: String
}

private extension String {
    var isLoopbackHost: Bool {
        self == "localhost" || self == "127.0.0.1" || self == "::1"
    }
}
