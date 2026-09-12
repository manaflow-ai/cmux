import Foundation

public struct CmxAttachTicket: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    /// The canonical on-the-wire keys. Most fields use camelCase; the auth
    /// token field is the one historical exception (`auth_token`).
    ///
    /// Encoding stays byte-compatible with what the mac side of PR 5079 already
    /// produces and decodes (this exact type is shared by both the iOS and mac
    /// app via `CMUXMobileCore`), so the mixed convention is preserved on the
    /// encode path. Decoding is tolerant: it accepts both the canonical
    /// `auth_token` key and a normalized camelCase `authToken` so a future
    /// producer can migrate the token field without breaking older clients.
    /// See ``decodeAuthToken(from:)``.
    private enum CodingKeys: String, CodingKey {
        case version
        case workspaceID
        case terminalID
        case macDeviceID
        case macDisplayName
        case macUserEmail
        case macUserID
        case macPairingCompatibilityVersion
        case macAppVersion
        case macAppBuild
        case routes
        case expiresAt
        case authToken = "auth_token"
    }

    /// Tolerant decode keys for the auth-token field only.
    ///
    /// Holds both the canonical `auth_token` key and the normalized `authToken`
    /// camelCase key so a payload speaking either convention decodes. The
    /// canonical key wins when both are present.
    private enum AuthTokenCodingKeys: String, CodingKey {
        case canonical = "auth_token"
        case camelCase = "authToken"
    }

    /// Per-entry lossy wrapper keeps a newly-added route kind from invalidating
    /// the legacy routes that an older client can still use.
    private struct FailableRoute: Decodable {
        let value: CmxAttachRoute?

        private enum CodingKeys: String, CodingKey {
            case kind
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawKind = try container.decode(String.self, forKey: .kind)
            guard CmxAttachTransportKind(rawValue: rawKind) == nil else {
                // Known routes retain their strict validation errors; only a
                // genuinely unknown enum value is forward-compatible.
                value = try CmxAttachRoute(from: decoder)
                return
            }
            value = nil
        }
    }

    public let version: Int
    public let workspaceID: String
    public let terminalID: String?
    public let macDeviceID: String
    public let macDisplayName: String?
    /// The signed-in Mac account email the phone must match before pairing.
    public let macUserEmail: String?
    /// The opaque Stack user id for the Mac account. Public pairing QR codes
    /// carry this instead of an email so the phone can reject the wrong
    /// signed-in account without exposing an enumerable email address.
    public let macUserID: String?
    /// Shared mobile pairing compatibility level reported by the Mac.
    public let macPairingCompatibilityVersion: Int?
    /// The Mac app's marketing version, displayed with compatibility warnings.
    public let macAppVersion: String?
    /// The Mac app's build number, displayed with version mismatch warnings when present.
    public let macAppBuild: String?
    public let routes: [CmxAttachRoute]
    /// When the ticket's attach token stops being usable, or `nil` for tickets
    /// that never expire (the pairing QR carries no token and no expiry; Stack
    /// auth is the host's sole authorization gate). Expiry is data for the
    /// token consumers (`MobileCoreRPCClient`, the host's ticket store), not a
    /// structural validity condition; see ``isExpired(at:)``.
    public let expiresAt: Date?
    public let authToken: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            workspaceID: container.decode(String.self, forKey: .workspaceID),
            terminalID: container.decodeIfPresent(String.self, forKey: .terminalID),
            macDeviceID: container.decode(String.self, forKey: .macDeviceID),
            macDisplayName: container.decodeIfPresent(String.self, forKey: .macDisplayName),
            macUserEmail: container.decodeIfPresent(String.self, forKey: .macUserEmail),
            macUserID: container.decodeIfPresent(String.self, forKey: .macUserID),
            macPairingCompatibilityVersion: container.decodeIfPresent(
                Int.self,
                forKey: .macPairingCompatibilityVersion
            ),
            macAppVersion: container.decodeIfPresent(String.self, forKey: .macAppVersion),
            macAppBuild: container.decodeIfPresent(String.self, forKey: .macAppBuild),
            routes: try container.decode([FailableRoute].self, forKey: .routes)
                .compactMap(\.value),
            expiresAt: container.decodeIfPresent(Date.self, forKey: .expiresAt),
            authToken: try Self.decodeAuthToken(from: decoder)
        )
        try validate()
    }

    /// Decode the auth token tolerantly, accepting either the canonical
    /// `auth_token` key or the normalized `authToken` key.
    ///
    /// - Parameter decoder: The decoder for the ticket payload.
    /// - Returns: The auth token if present under either key (`auth_token`
    ///   takes precedence), otherwise `nil`.
    private static func decodeAuthToken(from decoder: Decoder) throws -> String? {
        let container = try decoder.container(keyedBy: AuthTokenCodingKeys.self)
        if let canonical = try container.decodeIfPresent(String.self, forKey: .canonical) {
            return canonical
        }
        return try container.decodeIfPresent(String.self, forKey: .camelCase)
    }

    public init(
        version: Int = Self.currentVersion,
        workspaceID: String,
        terminalID: String?,
        macDeviceID: String,
        macDisplayName: String?,
        macUserEmail: String? = nil,
        macUserID: String? = nil,
        macPairingCompatibilityVersion: Int? = nil,
        macAppVersion: String? = nil,
        macAppBuild: String? = nil,
        routes: [CmxAttachRoute],
        expiresAt: Date? = nil,
        authToken: String? = nil
    ) throws {
        self.version = version
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        self.macDisplayName = macDisplayName
        self.macUserEmail = macUserEmail
        self.macUserID = macUserID
        self.macPairingCompatibilityVersion = macPairingCompatibilityVersion
        self.macAppVersion = macAppVersion
        self.macAppBuild = macAppBuild
        self.routes = routes
        self.expiresAt = expiresAt
        self.authToken = authToken
        try validate()
    }

    /// Structural validity only. Expiry is intentionally NOT validated here:
    /// a scanned pairing QR must keep working however long it sat on screen
    /// (the host authorizes by Stack account, not by ticket age). Token-based
    /// consumers check ``isExpired(at:)`` where the token is actually used.
    public func validate() throws {
        guard version == Self.currentVersion else {
            throw CmxAttachTicketError.unsupportedVersion(version)
        }
        if let authToken {
            guard !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CmxAttachTicketError.emptyAuthToken
            }
        }
        guard !routes.isEmpty else {
            throw CmxAttachTicketError.noRoutes
        }
        for route in routes {
            try route.validate()
        }
    }

    /// Whether the ticket's attach token lifetime has elapsed at `now`.
    /// Tickets without an expiry (`expiresAt == nil`, e.g. decoded from the
    /// pairing QR) never expire.
    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else {
            return false
        }
        return expiresAt <= now
    }

    public func preferredRoute(supportedKinds: [CmxAttachTransportKind]) -> CmxAttachRoute? {
        guard !supportedKinds.isEmpty else {
            return nil
        }
        let orderedRoutes = routes.sorted { left, right in
            if left.priority == right.priority {
                return left.id < right.id
            }
            return left.priority < right.priority
        }
        let supportedKinds = Set(supportedKinds)
        return orderedRoutes.first { supportedKinds.contains($0.kind) }
    }
}
