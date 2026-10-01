public import Foundation

/// Errors raised while obtaining a temporary ICE server set from the
/// authenticated development or production presence service.
public enum CmxWebRTCIceServerClientError: Error, Equatable, Sendable {
    case invalidServiceURL
    case notAuthenticated
    case redirected
    case requestFailed(Int)
    case invalidResponse
    case timedOut
}

/// Returns one coherent Stack access/refresh token pair. Keeping the pair in
/// one callback prevents a refresh between two independent token reads from
/// mixing credentials from different sessions on the same request.
public typealias CmxWebRTITokenProvider = @Sendable () async throws -> (
    accessToken: String,
    refreshToken: String?
)

private final class CmxWebRTCRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Authenticated client for `/v1/webrtc/ice-servers` on the presence Worker.
/// The Worker owns the Cloudflare TURN API secret; this client receives only
/// the resulting short-lived ICE credentials.
public actor CmxWebRTCIceServerClient {
    private let requestURL: URL?
    private let tokenProvider: CmxWebRTITokenProvider
    private let teamIDProvider: @Sendable () async throws -> String?
    private let session: URLSession
    private let requestTimeout: TimeInterval

    public init(
        serviceBaseURL: String,
        tokenProvider: @escaping CmxWebRTITokenProvider,
        teamIDProvider: @escaping @Sendable () async throws -> String? = { nil },
        session: URLSession? = nil,
        requestTimeout: TimeInterval = 10
    ) {
        requestURL = Self.iceServersURL(serviceBaseURL: serviceBaseURL)
        self.tokenProvider = tokenProvider
        self.teamIDProvider = teamIDProvider
        self.requestTimeout = max(1, requestTimeout)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = self.requestTimeout
            configuration.timeoutIntervalForResource = self.requestTimeout
            self.session = URLSession(
                configuration: configuration,
                delegate: CmxWebRTCRedirectRejectingDelegate(),
                delegateQueue: nil
            )
        }
    }

    /// Pure URL construction used by tests and to keep origin resolution in
    /// one place. The endpoint path is appended to the supplied Worker origin.
    public static func iceServersURL(serviceBaseURL: String) -> URL? {
        guard var components = URLComponents(string: serviceBaseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host != nil else {
            return nil
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + "/v1/webrtc/ice-servers"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Fetches and decodes the current account's temporary ICE servers.
    public func fetch() async throws -> [CmxWebRTCICEServer] {
        guard let requestURL else {
            throw CmxWebRTCIceServerClientError.invalidServiceURL
        }
        let tokens: (accessToken: String, refreshToken: String?)
        do {
            tokens = try await tokenProvider()
        } catch {
            throw CmxWebRTCIceServerClientError.notAuthenticated
        }
        guard !tokens.accessToken.isEmpty else {
            throw CmxWebRTCIceServerClientError.notAuthenticated
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let refreshToken = tokens.refreshToken, !refreshToken.isEmpty {
            request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        }
        if let teamID = try await teamIDProvider(), !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw CmxWebRTCIceServerClientError.timedOut
        } catch {
            throw CmxWebRTCIceServerClientError.invalidResponse
        }
        guard let http = response as? HTTPURLResponse else {
            throw CmxWebRTCIceServerClientError.invalidResponse
        }
        guard http.url?.scheme == requestURL.scheme,
              http.url?.host == requestURL.host,
              http.url?.port == requestURL.port else {
            throw CmxWebRTCIceServerClientError.redirected
        }
        guard (200...299).contains(http.statusCode) else {
            throw CmxWebRTCIceServerClientError.requestFailed(http.statusCode)
        }
        guard data.count <= 64 * 1024 else {
            throw CmxWebRTCIceServerClientError.invalidResponse
        }

        struct ArrayResponse: Decodable {
            let iceServers: [CmxWebRTCICEServer]
        }
        struct ObjectResponse: Decodable {
            let iceServers: CmxWebRTCICEServer
        }
        if let decoded = try? JSONDecoder().decode(ArrayResponse.self, from: data),
           !decoded.iceServers.isEmpty {
            return decoded.iceServers
        }
        if let decoded = try? JSONDecoder().decode(ObjectResponse.self, from: data) {
            return [decoded.iceServers]
        }
        throw CmxWebRTCIceServerClientError.invalidResponse
    }
}
