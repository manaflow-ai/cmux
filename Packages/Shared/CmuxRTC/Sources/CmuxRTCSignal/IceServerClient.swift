import Foundation

/// One ICE server as the backend returns it (`GET /v1/rtc/ice-servers`).
public struct RTCIceServerConfig: Codable, Sendable, Equatable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

/// The ICE configuration for one link: servers plus how long the TURN credentials last.
public struct RTCIceConfiguration: Codable, Sendable, Equatable {
    public let servers: [RTCIceServerConfig]
    public let ttl: Int
    /// False when the backend has no TURN (STUN only): links across symmetric NATs will fail.
    public let turn: Bool

    public init(servers: [RTCIceServerConfig], ttl: Int, turn: Bool) {
        self.servers = servers
        self.ttl = ttl
        self.turn = turn
    }

    /// Used when the backend cannot be reached: Cloudflare's public STUN only.
    public static let stunOnly = RTCIceConfiguration(servers: [RTCIceServerConfig(urls: ["stun:stun.cloudflare.com:3478"])], ttl: 3600, turn: false)

    enum CodingKeys: String, CodingKey {
        case servers = "ice_servers"
        case ttl, turn
    }
}

public enum RTCIceServerClientError: Error, Equatable {
    case status(Int)
}

public struct IceServerClient: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL: URL
    private let fetch: Fetch

    public init(baseURL: URL, fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.baseURL = baseURL
        self.fetch = fetch
    }

    public func configuration(bearer: String) async throws -> RTCIceConfiguration {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/rtc/ice-servers"))
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw RTCIceServerClientError.status(status) }
        return try JSONDecoder().decode(RTCIceConfiguration.self, from: data)
    }
}
