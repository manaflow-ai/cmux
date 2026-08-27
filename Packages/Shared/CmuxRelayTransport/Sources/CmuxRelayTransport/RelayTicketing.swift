// Ticket minting client. The web app is the only authority that turns a
// Stack session into relay access (POST /api/mobile-relay/ticket, native
// bearer + refresh headers); this client is a thin typed wrapper both
// platforms reuse with injected auth. Stack tokens go to the WEB API only,
// never to the relay socket: the minted ticket is the sole relay credential.

import Foundation

public struct RelayTicketGrant: Sendable, Equatable {
    public let ticket: String
    public let relayURL: URL
    public let expiresAt: Date
    public let protocolVersion: Int

    public init(ticket: String, relayURL: URL, expiresAt: Date, protocolVersion: Int) {
        self.ticket = ticket
        self.relayURL = relayURL
        self.expiresAt = expiresAt
        self.protocolVersion = protocolVersion
    }
}

public protocol RelayTicketProviding: Sendable {
    func mintTicket(hostDeviceID: String, deviceID: String, role: RelayRole) async throws -> RelayTicketGrant
}

public enum RelayTicketError: Error, Equatable, Sendable {
    /// No signed-in account or no API base URL; minting is impossible.
    case notAuthenticated
    /// The backend has no relay secret provisioned (503 relay_not_configured).
    case relayNotConfigured
    /// The caller does not own the host device (403) or auth failed (401).
    case notAuthorized
    case httpStatus(Int)
    case invalidResponse
}

/// Fetches tickets from the cmux web API using injected credentials, so the
/// package stays free of platform auth types. `authorizationHeaders` returns
/// the native Stack headers (`Authorization`, `X-Stack-Refresh-Token`), or
/// nil when signed out.
public struct RelayTicketClient: RelayTicketProviding {
    public typealias BaseURLProvider = @Sendable () async -> URL?
    public typealias HeaderProvider = @Sendable () async -> [String: String]?

    private let apiBaseURL: BaseURLProvider
    private let authorizationHeaders: HeaderProvider
    private let urlSession: URLSession

    public init(
        apiBaseURL: @escaping BaseURLProvider,
        authorizationHeaders: @escaping HeaderProvider,
        urlSession: URLSession = .shared
    ) {
        self.apiBaseURL = apiBaseURL
        self.authorizationHeaders = authorizationHeaders
        self.urlSession = urlSession
    }

    private struct RequestBody: Encodable {
        let hostDeviceId: String
        let deviceId: String
        let role: String
    }

    private struct ResponseBody: Decodable {
        let ticket: String
        let relayUrl: String
        let expiresAt: Double
        let protocolVersion: Int
    }

    public func mintTicket(
        hostDeviceID: String,
        deviceID: String,
        role: RelayRole
    ) async throws -> RelayTicketGrant {
        guard let baseURL = await apiBaseURL(),
              let headers = await authorizationHeaders() else {
            throw RelayTicketError.notAuthenticated
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/mobile-relay/ticket"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(RequestBody(
            hostDeviceId: hostDeviceID,
            deviceId: deviceID,
            role: role.rawValue
        ))
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayTicketError.invalidResponse }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw RelayTicketError.notAuthorized
        case 503:
            throw RelayTicketError.relayNotConfigured
        default:
            throw RelayTicketError.httpStatus(http.statusCode)
        }
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let relayURL = URL(string: body.relayUrl) else {
            throw RelayTicketError.invalidResponse
        }
        return RelayTicketGrant(
            ticket: body.ticket,
            relayURL: relayURL,
            expiresAt: Date(timeIntervalSince1970: body.expiresAt),
            protocolVersion: body.protocolVersion
        )
    }
}
