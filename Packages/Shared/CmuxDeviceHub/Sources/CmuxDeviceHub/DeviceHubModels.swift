public import Foundation

/// The records the device hub answers with (PROTOCOL.md, HTTP API). Fields
/// other than ids decode leniently: a missing or differently typed optional
/// field is nil, so a newer server never breaks an older app.

public enum DevicePlatform: String, Codable, Sendable, Equatable {
    case macos, ios
}

/// What a viewer may do on a host's screen.
public enum DeviceScope: String, Codable, Sendable, Equatable, CaseIterable {
    case none, ask, view, full
}

/// The scope a session runs with (never `none` or `ask`).
public enum SessionScope: String, Codable, Sendable, Equatable {
    case view, full
}

public struct HubDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var platform: DevicePlatform?
    /// base64 X9.63 signing key.
    public var signingKey: String?
    /// base64 X9.63 key agreement key (relay secrets are sealed to it).
    public var agreementKey: String?
    public var createdAt: Date?
    public var lastSeenAt: Date?
    public var macScreenShared: Bool
    public var online: Bool

    public init(id: String, name: String, platform: DevicePlatform? = nil, signingKey: String? = nil, agreementKey: String? = nil,
                createdAt: Date? = nil, lastSeenAt: Date? = nil, macScreenShared: Bool = false, online: Bool = false) {
        self.id = id; self.name = name; self.platform = platform; self.signingKey = signingKey
        self.agreementKey = agreementKey; self.createdAt = createdAt; self.lastSeenAt = lastSeenAt
        self.macScreenShared = macScreenShared; self.online = online
    }

    /// The signing key's display fingerprint, when the key is valid.
    public var fingerprint: String? { signingKey.flatMap(DeviceIdentity.fingerprint(signingKey:)) }

    enum CodingKeys: String, CodingKey {
        case id, name, platform, signingKey, agreementKey, createdAt, lastSeenAt, macScreenShared, online
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? ""
        platform = c.lenient(DevicePlatform.self, .platform)
        signingKey = c.lenient(String.self, .signingKey)
        agreementKey = c.lenient(String.self, .agreementKey)
        createdAt = c.date(.createdAt)
        lastSeenAt = c.date(.lastSeenAt)
        macScreenShared = c.flag(.macScreenShared)
        online = c.flag(.online)
    }
}

public struct HubPermission: Codable, Sendable, Equatable {
    public var hostId: String?
    public var viewerId: String
    public var scope: DeviceScope

    public init(hostId: String? = nil, viewerId: String, scope: DeviceScope) {
        self.hostId = hostId; self.viewerId = viewerId; self.scope = scope
    }

    enum CodingKeys: String, CodingKey { case hostId, viewerId, scope }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostId = c.lenient(String.self, .hostId)
        viewerId = try c.decode(String.self, forKey: .viewerId)
        scope = c.lenient(DeviceScope.self, .scope) ?? .ask
    }
}

public enum RelayAuthMode: String, Codable, Sendable, Equatable {
    case sharedSecret = "shared_secret"
    case `static`
}

public struct HubRelay: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var urls: [String]
    public var authMode: RelayAuthMode
    /// This device's sealed secret (base64, ``RelaySealing``), when the server sent one.
    public var sealedForThisDevice: String?
    public var enabled: Bool
    public var priority: Int
    public var updatedAt: Date?

    public init(id: String, name: String, urls: [String], authMode: RelayAuthMode, sealedForThisDevice: String? = nil,
                enabled: Bool = true, priority: Int = 0, updatedAt: Date? = nil) {
        self.id = id; self.name = name; self.urls = urls; self.authMode = authMode
        self.sealedForThisDevice = sealedForThisDevice; self.enabled = enabled; self.priority = priority; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case id, name, urls, authMode, sealed, enabled, priority, updatedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? ""
        urls = c.lenient([String].self, .urls) ?? []
        authMode = c.lenient(RelayAuthMode.self, .authMode) ?? .static
        // "Each relay carries only this device's sealed blob": a one-entry map or the blob itself.
        sealedForThisDevice = c.lenient(String.self, .sealed) ?? c.lenient([String: String].self, .sealed)?.values.first
        enabled = c.lenient(Bool.self, .enabled) ?? (c.lenient(Int.self, .enabled).map { $0 != 0 } ?? true)
        priority = c.lenient(Int.self, .priority) ?? 0
        updatedAt = c.date(.updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(urls, forKey: .urls)
        try c.encode(authMode, forKey: .authMode)
        try c.encodeIfPresent(sealedForThisDevice, forKey: .sealed)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(priority, forKey: .priority)
    }
}

public enum SessionState: String, Codable, Sendable, Equatable {
    case pending, approved, live, ended
}

public struct HubSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var state: SessionState?
    public var scope: SessionScope?

    public init(id: String, state: SessionState? = nil, scope: SessionScope? = nil) {
        self.id = id; self.state = state; self.scope = scope
    }

    enum CodingKeys: String, CodingKey { case id, state, scope }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = c.lenient(SessionState.self, .state)
        scope = c.lenient(SessionScope.self, .scope)
    }
}

public enum SessionDecision: String, Codable, Sendable, Equatable {
    case deny, once, always
}

public struct AuditEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var ts: Date?
    /// `shared`, `unshared`, `requested`, `approved`, `denied`, `started`, `ended`,
    /// `permission_changed`, `device_added`, `device_removed`.
    public var event: String
    public var viewerId: String?
    public var hostId: String?
    /// The device a `device_added` / `device_removed` entry is about.
    public var deviceId: String?
    /// The devices' names as the hub knew them, kept after a device is removed.
    public var viewerName: String?
    public var hostName: String?
    public var deviceName: String?
    public var scope: String?
    public var sessionId: String?
    public var detail: String?
    public var durationS: Double?

    public init(id: String, ts: Date? = nil, event: String, viewerId: String? = nil, hostId: String? = nil, deviceId: String? = nil,
                scope: String? = nil, sessionId: String? = nil, detail: String? = nil, durationS: Double? = nil) {
        self.id = id; self.ts = ts; self.event = event; self.viewerId = viewerId; self.hostId = hostId; self.deviceId = deviceId
        self.scope = scope; self.sessionId = sessionId; self.detail = detail; self.durationS = durationS
    }

    enum CodingKeys: String, CodingKey {
        case id, ts, event, viewerId, hostId, deviceId, viewerName, hostName, deviceName, scope, sessionId, detail, durationS, duration_s
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ts = c.date(.ts)
        event = c.lenient(String.self, .event) ?? ""
        viewerId = c.lenient(String.self, .viewerId)
        hostId = c.lenient(String.self, .hostId)
        deviceId = c.lenient(String.self, .deviceId)
        viewerName = c.lenient(String.self, .viewerName)
        hostName = c.lenient(String.self, .hostName)
        deviceName = c.lenient(String.self, .deviceName)
        scope = c.lenient(String.self, .scope)
        sessionId = c.lenient(String.self, .sessionId)
        detail = c.lenient(String.self, .detail)
        durationS = c.lenient(Double.self, .durationS) ?? c.lenient(Double.self, .duration_s)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(ts?.timeIntervalSince1970, forKey: .ts)
        try c.encode(event, forKey: .event)
        try c.encodeIfPresent(viewerId, forKey: .viewerId)
        try c.encodeIfPresent(hostId, forKey: .hostId)
        try c.encodeIfPresent(deviceId, forKey: .deviceId)
        try c.encodeIfPresent(viewerName, forKey: .viewerName)
        try c.encodeIfPresent(hostName, forKey: .hostName)
        try c.encodeIfPresent(deviceName, forKey: .deviceName)
        try c.encodeIfPresent(scope, forKey: .scope)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(durationS, forKey: .durationS)
    }
}

public enum DevicePlan: String, Codable, Sendable, Equatable {
    case free, paid
}

/// `GET /v1/me`.
public struct HubMe: Codable, Sendable, Equatable {
    public var userId: String
    public var plan: DevicePlan
    public var device: HubDevice?

    public init(userId: String, plan: DevicePlan, device: HubDevice? = nil) {
        self.userId = userId; self.plan = plan; self.device = device
    }

    enum CodingKeys: String, CodingKey { case userId, plan, device }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        plan = c.lenient(DevicePlan.self, .plan) ?? .free
        device = c.lenient(HubDevice.self, .device)
    }
}

/// One ICE server (`{urls, username, credential}`), as the server's `ice`
/// lists and the user's relays give them.
public struct DeviceHubICEServer: Codable, Sendable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls; self.username = username; self.credential = credential
    }

    enum CodingKeys: String, CodingKey { case urls, username, credential }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // WebRTC allows one URL as a string.
        urls = c.lenient([String].self, .urls) ?? c.lenient(String.self, .urls).map { [$0] } ?? []
        username = c.lenient(String.self, .username)
        credential = c.lenient(String.self, .credential)
    }
}

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// A boolean sent as `true`/`false` or as SQLite's `1`/`0`.
    func flag(_ key: Key) -> Bool {
        lenient(Bool.self, key) ?? (lenient(Int.self, key).map { $0 != 0 } ?? false)
    }

    /// Unix seconds, unix milliseconds (above 1e11) or an ISO 8601 string.
    func date(_ key: Key) -> Date? {
        if let number = lenient(Double.self, key) {
            return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
        }
        guard let text = lenient(String.self, key) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
