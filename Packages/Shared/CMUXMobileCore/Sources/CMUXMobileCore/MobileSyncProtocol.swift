import Foundation

/// Shared default constants for the mobile sync protocol.
public struct CmxMobileDefaults {
    private init() {}

    /// The default daemon host port mobile clients dial when none is supplied.
    public static let defaultHostPort = 58_465
    /// Shared Mac/iOS pairing compatibility level. Bump this only when current
    /// clients can pair but may behave incorrectly without explicit user approval.
    public static let pairingCompatibilityVersion = 1
}

public enum CmxAttachTransportKind: String, Codable, Sendable {
    case tailscale
    case manualHost = "manual_host"
    case iroh
    case websocket
    case debugLoopback = "debug_loopback"
}

public typealias MobileSyncTransportKind = CmxAttachTransportKind

public enum MobileSyncPairingPayloadError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case emptyHost
    case invalidPort(Int)
    case expired
    case forbiddenSecretField(String)
    case invalidURL
    case invalidPayloadEncoding
    /// A scanned/pasted pairing code only offered loopback routes. A QR or
    /// deep link pointing at `127.0.0.1` would make the phone dial itself,
    /// so it is rejected with a clear error instead of a doomed connect;
    /// loopback pairing is reserved for the dev-injected attach URL path.
    case loopbackRouteRejected
    /// A pairing/attach URL whose grammar version (`v=`) is newer than this
    /// build understands. The associated value is the version read off the URL.
    /// Surfaced distinctly so the user is told to update the app rather than
    /// shown the generic "not a valid code" copy.
    case unrecognizedURLVersion(Int)
}

public struct MobileSyncPairingPayload: Equatable, Sendable, Codable {
    public static let currentVersion = 1
    private static let validationDateUserInfoKey = CodingUserInfoKey(
        rawValue: "dev.cmux.mobileSyncPairingPayload.validationDate"
    )!

    public let version: Int
    public let macDeviceID: String
    public let macDisplayName: String?
    public let host: String
    public let port: Int
    public let expiresAt: Date
    public let transport: MobileSyncTransportKind

    public init(
        version: Int = Self.currentVersion,
        macDeviceID: String,
        macDisplayName: String?,
        host: String,
        port: Int,
        expiresAt: Date,
        transport: MobileSyncTransportKind
    ) throws {
        self.version = version
        self.macDeviceID = macDeviceID
        self.macDisplayName = macDisplayName
        self.host = host
        self.port = port
        self.expiresAt = expiresAt
        self.transport = transport
        try validate(now: Date())
    }

    public init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: DynamicCodingKey.self)
        for key in keyed.allKeys {
            let normalizedKey = key.stringValue.lowercased()
            if Self.forbiddenSecretKeyMarkers.contains(where: { normalizedKey.contains($0) }) {
                throw MobileSyncPairingPayloadError.forbiddenSecretField(key.stringValue)
            }
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        macDeviceID = try container.decode(String.self, forKey: .macDeviceID)
        macDisplayName = try container.decodeIfPresent(String.self, forKey: .macDisplayName)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        transport = try container.decode(MobileSyncTransportKind.self, forKey: .transport)
        let now = decoder.userInfo[Self.validationDateUserInfoKey] as? Date ?? Date()
        try validate(now: now)
    }

    public func validate(now: Date = Date()) throws {
        guard version == Self.currentVersion else {
            throw MobileSyncPairingPayloadError.unsupportedVersion(version)
        }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MobileSyncPairingPayloadError.emptyHost
        }
        guard (1...65535).contains(port) else {
            throw MobileSyncPairingPayloadError.invalidPort(port)
        }
        guard expiresAt > now else {
            throw MobileSyncPairingPayloadError.expired
        }
    }

    public func encodedURL() throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let payload = Self.base64URLEncode(data)
        guard let url = URL(string: "\(CmxPairingURLScheme.current)://pair?v=\(version)&payload=\(payload)") else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        return url
    }

    public static func decodeURL(_ url: URL, now: Date = Date()) throws -> MobileSyncPairingPayload {
        guard CmxPairingURLScheme.isPairingScheme(url.scheme),
              url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encodedPayload = components.queryItems?.first(where: { $0.name == "payload" })?.value,
              let data = base64URLDecode(encodedPayload) else {
            throw MobileSyncPairingPayloadError.invalidURL
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[validationDateUserInfoKey] = now
        let payload = try decoder.decode(MobileSyncPairingPayload.self, from: data)
        return payload
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case macDeviceID = "mac_device_id"
        case macDisplayName = "mac_display_name"
        case host
        case port
        case expiresAt = "expires_at"
        case transport
    }

    private static let forbiddenSecretKeyMarkers: Set<String> = [
        "auth",
        "authorization",
        "bearer",
        "credential",
        "jwt",
        "password",
        "secret",
        "token",
    ]

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        return Data(base64Encoded: base64)
    }
}

public enum MobileSyncFrameCodecError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
}

/// Length-prefixed frame codec for the mobile sync wire protocol.
public struct MobileSyncFrameCodec {
    private init() {}

    public static let headerByteCount = 4
    public static let defaultMaximumFrameByteCount = 8 * 1024 * 1024

    public static func encodeFrame(_ payload: Data) throws -> Data {
        guard payload.count <= defaultMaximumFrameByteCount else {
            throw MobileSyncFrameCodecError.frameTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: headerByteCount)
        frame.append(payload)
        return frame
    }

    public static func decodeFrames(
        from buffer: inout Data,
        maximumFrameByteCount: Int = defaultMaximumFrameByteCount
    ) throws -> [Data] {
        var frames: [Data] = []
        while buffer.count >= headerByteCount {
            let length = buffer.prefix(headerByteCount).reduce(UInt32(0)) { partial, byte in
                (partial << 8) | UInt32(byte)
            }
            let payloadLength = Int(length)
            guard payloadLength <= maximumFrameByteCount else {
                throw MobileSyncFrameCodecError.frameTooLarge(payloadLength)
            }
            guard buffer.count >= headerByteCount + payloadLength else {
                break
            }
            let payloadStart = headerByteCount
            let payloadEnd = payloadStart + payloadLength
            frames.append(buffer.subdata(in: payloadStart..<payloadEnd))
            buffer.removeSubrange(0..<payloadEnd)
        }
        return frames
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
