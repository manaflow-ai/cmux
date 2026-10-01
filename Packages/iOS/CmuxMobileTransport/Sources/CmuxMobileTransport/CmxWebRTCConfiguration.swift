public import Foundation

/// A serializable ICE server entry used to configure an experimental WebRTC
/// data channel without exposing native WebRTC objects to the app target.
public struct CmxWebRTCICEServer: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case urls
        case username
        case credential
    }

    /// The STUN or TURN URLs advertised by this server.
    public let urls: [String]
    /// The TURN username, when the server requires authentication.
    public let username: String?
    /// The TURN credential, when the server requires authentication.
    public let credential: String?

    /// Creates an ICE server entry.
    ///
    /// - Parameters:
    ///   - urls: STUN or TURN URLs accepted by WebRTC.
    ///   - username: An optional TURN username.
    ///   - credential: An optional TURN credential.
    public init(
        urls: [String],
        username: String? = nil,
        credential: String? = nil
    ) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    /// Decodes both WebRTC's array form and Cloudflare's single-URL shorthand.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let urls = try? container.decode([String].self, forKey: .urls) {
            self.urls = urls
        } else {
            self.urls = [try container.decode(String.self, forKey: .urls)]
        }
        username = try container.decodeIfPresent(String.self, forKey: .username)
        credential = try container.decodeIfPresent(String.self, forKey: .credential)
    }
}

/// Value configuration shared by the iOS WebRTC client and macOS signaling host.
public struct CmxWebRTCConfiguration: Equatable, Sendable {
    /// Cloudflare's public STUN endpoint, useful when no TURN credentials are configured.
    public static let cloudflareSTUN = CmxWebRTCICEServer(urls: ["stun:stun.cloudflare.com:3478"])

    /// The environment key used by tagged experimental builds.
    public static let experimentEnvironmentKey = "CMUX_WEBRTC_EXPERIMENT"

    /// ICE servers tried by each peer connection.
    public let iceServers: [CmxWebRTCICEServer]
    /// Whether ICE must select a TURN relay candidate.
    public let forceRelay: Bool
    /// Deadline for the TCP signaling connection.
    public let signalingTimeoutNanoseconds: UInt64
    /// Deadline for the WebRTC peer connection to open its data channel.
    public let connectionTimeoutNanoseconds: UInt64

    /// Creates a WebRTC configuration.
    ///
    /// - Parameters:
    ///   - iceServers: ICE servers. Cloudflare STUN is the default.
    ///   - forceRelay: When true, host candidates are excluded and TURN is required.
    ///   - signalingTimeoutNanoseconds: TCP signaling deadline.
    ///   - connectionTimeoutNanoseconds: Data-channel readiness deadline.
    public init(
        iceServers: [CmxWebRTCICEServer] = [Self.cloudflareSTUN],
        forceRelay: Bool = false,
        signalingTimeoutNanoseconds: UInt64 = 15 * 1_000_000_000,
        connectionTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    ) {
        self.iceServers = iceServers.filter { !$0.urls.isEmpty }
        self.forceRelay = forceRelay
        self.signalingTimeoutNanoseconds = max(1, signalingTimeoutNanoseconds)
        self.connectionTimeoutNanoseconds = max(1, connectionTimeoutNanoseconds)
    }

    /// Builds configuration from an injected environment and optional defaults.
    ///
    /// `CMUX_WEBRTC_ICE_SERVERS_JSON` accepts either an array of server objects
    /// or Cloudflare's response shape, `{ "iceServers": { ... } }`. The value
    /// is intentionally read at construction time so credentials never become
    /// a process-wide mutable setting.
    ///
    /// - Parameters:
    ///   - environment: Environment values supplied by the composition root.
    ///   - userDefaults: Optional defaults store used when the environment has no ICE JSON.
    public init(environment: [String: String], userDefaults: UserDefaults? = nil) {
        let defaultsJSON = userDefaults?.string(forKey: "cmux.webrtc.ice-servers-json")
        let rawJSON = environment["CMUX_WEBRTC_ICE_SERVERS_JSON"] ?? defaultsJSON
        let parsedServers = rawJSON.flatMap(Self.decodeServers)
        self.init(
            iceServers: parsedServers?.isEmpty == false
                ? parsedServers ?? [Self.cloudflareSTUN]
                : [Self.cloudflareSTUN],
            forceRelay: Self.boolean(
                environment["CMUX_WEBRTC_FORCE_RELAY"]
                    ?? userDefaults?.string(forKey: "cmux.webrtc.force-relay")
            ),
            signalingTimeoutNanoseconds: Self.nanoseconds(
                environment["CMUX_WEBRTC_SIGNALING_TIMEOUT_NS"]
            ) ?? 15 * 1_000_000_000,
            connectionTimeoutNanoseconds: Self.nanoseconds(
                environment["CMUX_WEBRTC_CONNECTION_TIMEOUT_NS"]
            ) ?? 30 * 1_000_000_000
        )
    }

    /// Returns true only for an explicit `1` value in the supplied environment
    /// or build Info.plist. The plist fallback keeps an isolated tagged build
    /// enabled when it is launched later by Finder or the tag opener.
    public static func isExperimentEnabled(
        environment: [String: String],
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> Bool {
        environment[experimentEnvironmentKey] == "1"
            || (infoDictionary?["CMUXWebRTCExperiment"] as? String) == "1"
    }

    private static func decodeServers(_ raw: String) -> [CmxWebRTCICEServer]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        if let servers = try? JSONDecoder().decode([CmxWebRTCICEServer].self, from: data) {
            return servers
        }
        struct CloudflareArrayResponse: Decodable {
            let iceServers: [CmxWebRTCICEServer]
        }
        if let response = try? JSONDecoder().decode(CloudflareArrayResponse.self, from: data) {
            return response.iceServers
        }
        struct CloudflareObjectResponse: Decodable {
            let iceServers: CmxWebRTCICEServer
        }
        return (try? JSONDecoder().decode(CloudflareObjectResponse.self, from: data))
            .map { [$0.iceServers] }
    }

    private static func boolean(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    private static func nanoseconds(_ value: String?) -> UInt64? {
        guard let value, let number = UInt64(value), number > 0 else { return nil }
        return number
    }
}
