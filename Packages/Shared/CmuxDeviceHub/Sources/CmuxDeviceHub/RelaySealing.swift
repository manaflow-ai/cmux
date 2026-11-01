public import CryptoKit
public import Foundation

/// A relay's secret, as the configuring device enters it.
public enum RelaySecret: Codable, Sendable, Equatable {
    /// TURN REST shared secret: each device mints short-lived credentials from it.
    case sharedSecret(String)
    /// A fixed username and password.
    case `static`(username: String, password: String)

    public var authMode: RelayAuthMode {
        switch self {
        case .sharedSecret: .sharedSecret
        case .static: .static
        }
    }

    /// `{"mode":"shared_secret","secret":…}` or `{"mode":"static","username":…,"password":…}`.
    enum CodingKeys: String, CodingKey { case mode, secret, username, password }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(RelayAuthMode.self, forKey: .mode) {
        case .sharedSecret: self = .sharedSecret(try c.decode(String.self, forKey: .secret))
        case .static: self = .static(username: try c.decode(String.self, forKey: .username), password: try c.decode(String.self, forKey: .password))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(authMode, forKey: .mode)
        switch self {
        case let .sharedSecret(secret): try c.encode(secret, forKey: .secret)
        case let .static(username, password):
            try c.encode(username, forKey: .username)
            try c.encode(password, forKey: .password)
        }
    }
}

/// Relay secrets sealed per device (PROTOCOL.md, Relays): HPKE base mode
/// (P-256, HKDF-SHA256, AES-256-GCM) to each device's `agreementKey`. A blob
/// is base64 of the 65-byte encapsulated key followed by the ciphertext; the
/// HPKE info is `cmux-device-hub relay v1 <relay id>`, so a blob opens only
/// as the relay it was sealed for. The plaintext is the ``RelaySecret`` JSON
/// (`{"mode":"shared_secret","secret":…}` or `{"mode":"static","username":…,"password":…}`).
public struct RelaySealing: Sendable {
    public static let ciphersuite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    static let encapsulatedKeyLength = 65

    public enum Failure: Error, Equatable, Sendable {
        case badRecipientKey
        case badBlob
        case badSecret
    }

    /// This device's identity: opens blobs sealed to it.
    public let identity: DeviceIdentity

    public init(identity: DeviceIdentity) {
        self.identity = identity
    }

    static func info(relayID: String) -> Data { Data("cmux-device-hub relay v1 \(relayID)".utf8) }

    /// `secret` sealed to one device's base64 X9.63 agreement key.
    public static func seal(_ secret: RelaySecret, relayID: String, to agreementKey: String) throws -> String {
        guard let keyData = Data(base64Encoded: agreementKey),
              let key = try? P256.KeyAgreement.PublicKey(x963Representation: keyData) else { throw Failure.badRecipientKey }
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: ciphersuite, info: info(relayID: relayID))
        let ciphertext = try sender.seal(try JSONEncoder().encode(secret))
        return (sender.encapsulatedKey + ciphertext).base64EncodedString()
    }

    /// `secret` sealed to every device with an agreement key: `{deviceId: blob}`.
    public static func seal(_ secret: RelaySecret, relayID: String, for devices: [HubDevice]) throws -> [String: String] {
        var sealed: [String: String] = [:]
        for device in devices {
            guard let key = device.agreementKey else { continue }
            sealed[device.id] = try seal(secret, relayID: relayID, to: key)
        }
        return sealed
    }

    /// Opens a blob sealed to this device.
    public func open(_ blob: String, relayID: String) throws -> RelaySecret {
        guard let data = Data(base64Encoded: blob), data.count > Self.encapsulatedKeyLength else { throw Failure.badBlob }
        let plaintext = try identity.keys.open(data.dropFirst(Self.encapsulatedKeyLength), encapsulatedKey: data.prefix(Self.encapsulatedKeyLength),
                                               info: Self.info(relayID: relayID))
        do { return try JSONDecoder().decode(RelaySecret.self, from: plaintext) } catch { throw Failure.badSecret }
    }

    /// TURN REST credentials from a shared secret: `username = "<expiry>:<label>"`,
    /// `credential = base64(HMAC-SHA1(secret, username))`, expiry six hours from `now`.
    /// The label is ``relayLabel(deviceName:deviceID:)``: TURN servers (coturn)
    /// refuse a username with spaces or curly quotes, which default Mac names have.
    public static func sharedSecretCredential(secret: String, deviceName: String, deviceID: String = "", now: Date,
                                              lifetime: TimeInterval = 6 * 3600) -> (username: String, credential: String, expires: Date) {
        let expires = Date(timeIntervalSince1970: (now.timeIntervalSince1970 + lifetime).rounded(.down))
        let username = "\(Int(expires.timeIntervalSince1970)):\(relayLabel(deviceName: deviceName, deviceID: deviceID))"
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(username.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return (username, Data(mac).base64EncodedString(), expires)
    }

    /// A device's name as a TURN username label: lowercase ASCII letters,
    /// digits and single dashes (apostrophes dropped, diacritics folded), at
    /// most 32 characters; the first 8 of the device id when nothing is left,
    /// and `device` when there is no id either. Never empty.
    public static func relayLabel(deviceName: String, deviceID: String) -> String {
        let folded = deviceName.replacingOccurrences(of: "\u{2019}", with: "").replacingOccurrences(of: "'", with: "")
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var label = ""
        for scalar in folded.unicodeScalars {
            if ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar) {
                label.unicodeScalars.append(scalar)
            } else if !label.isEmpty, !label.hasSuffix("-") {
                label.append("-")
            }
        }
        label = String(label.prefix(32))
        while label.hasSuffix("-") { label.removeLast() }
        if !label.isEmpty { return label }
        let id = deviceID.lowercased().unicodeScalars.filter { ("a" ... "z").contains($0) || ("0" ... "9").contains($0) }
        return id.isEmpty ? "device" : String(String(id).prefix(8))
    }

    /// The ICE server for one relay and its opened secret.
    public static func iceServer(_ relay: HubRelay, secret: RelaySecret, deviceName: String, deviceID: String = "",
                                 now: Date) -> DeviceHubICEServer {
        switch secret {
        case let .sharedSecret(shared):
            let minted = sharedSecretCredential(secret: shared, deviceName: deviceName, deviceID: deviceID, now: now)
            return DeviceHubICEServer(urls: relay.urls, username: minted.username, credential: minted.credential)
        case let .static(username, password):
            return DeviceHubICEServer(urls: relay.urls, username: username, credential: password)
        }
    }
}
