import Foundation
enum BrowserWebAuthnBridgeMessageKind: String {
    case capabilities
    case createCredential
    case getCredential
}
private enum BrowserWebAuthnErrorName: String {
    case invalidState = "InvalidStateError"
    case notAllowed = "NotAllowedError"
    case notSupported = "NotSupportedError"
    case security = "SecurityError"
    case type = "TypeError"
    case unknown = "UnknownError"
}
struct BrowserWebAuthnBridgeError: Error {
    private let name: BrowserWebAuthnErrorName
    private let message: String

    func replyObject() -> [String: Any] {
        [
            "ok": false,
            "error": [
                "name": name.rawValue,
                "message": message,
            ],
        ]
    }

    static func invalidState(_ message: String) -> Self {
        .init(name: .invalidState, message: message)
    }

    static func notAllowed(_ message: String) -> Self {
        .init(name: .notAllowed, message: message)
    }

    static func notSupported(_ message: String) -> Self {
        .init(name: .notSupported, message: message)
    }

    static func security(_ message: String) -> Self {
        .init(name: .security, message: message)
    }

    static func type(_ message: String) -> Self {
        .init(name: .type, message: message)
    }

    static func unknown(_ message: String) -> Self {
        .init(name: .unknown, message: message)
    }
}

struct BrowserWebAuthnMessageEnvelope {
    let kind: BrowserWebAuthnBridgeMessageKind
    fileprivate let payloadJSON: String?
}

enum BrowserWebAuthnRequestParser {
    private static let maximumKindUTF8Bytes = 64
    private static let maximumPayloadJSONUTF8Bytes = 512 * 1024
    fileprivate static let maximumInboundBinaryBytes = 1024
    fileprivate static let maximumInboundBase64URLCharacters = ((maximumInboundBinaryBytes + 2) / 3) * 4
    fileprivate static let challengeByteRange = 1 ... maximumInboundBinaryBytes
    fileprivate static let userIDByteRange = 1 ... 64
    fileprivate static let credentialIDByteRange = 1 ... maximumInboundBinaryBytes
    fileprivate static let maximumCredentialDescriptors = 128
    fileprivate static let maximumCredentialTransports = 8
    fileprivate static let maximumCredentialParameters = 32
    fileprivate static let maximumShortStringUTF8Bytes = 64
    fileprivate static let maximumRelyingPartyIDUTF8Bytes = 253
    fileprivate static let maximumDisplayStringUTF8Bytes = 1024
    fileprivate static let maximumAppIDUTF8Bytes = 2048

    static func parseEnvelope(from body: Any) throws -> BrowserWebAuthnMessageEnvelope {
        guard let root = body as? [String: Any],
              let rawKind = root["kind"] as? String,
              rawKind.utf8.count <= maximumKindUTF8Bytes,
              let kind = BrowserWebAuthnBridgeMessageKind(rawValue: rawKind) else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }

        let payloadJSON: String?
        if let rawPayload = root["payload"] {
            guard let payload = rawPayload as? String,
                  payload.utf8.count <= maximumPayloadJSONUTF8Bytes else {
                throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
            }
            payloadJSON = payload
        } else {
            payloadJSON = nil
        }

        return .init(kind: kind, payloadJSON: payloadJSON)
    }

    static func decodePayload<T: Decodable>(
        _ type: T.Type,
        from envelope: BrowserWebAuthnMessageEnvelope
    ) throws -> T {
        guard let payloadJSON = envelope.payloadJSON,
              let payloadData = payloadJSON.data(using: .utf8) else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }

        do {
            return try JSONDecoder().decode(T.self, from: payloadData)
        } catch {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
    }
}

struct BrowserWebAuthnBinaryData: Decodable {
    let data: Data

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard encoded.utf8.count <= BrowserWebAuthnRequestParser.maximumInboundBase64URLCharacters,
              encoded.utf8.allSatisfy(\.isWebAuthnBase64URLByte) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid base64url-encoded WebAuthn binary value."
            )
        }
        guard let data = Data(base64URLEncoded: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid base64url-encoded WebAuthn binary value."
            )
        }
        guard data.count <= BrowserWebAuthnRequestParser.maximumInboundBinaryBytes else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "WebAuthn binary value is too large."
            )
        }
        self.data = data
    }
}

struct BrowserWebAuthnCredentialDescriptor: Decodable {
    let type: String?
    let id: BrowserWebAuthnBinaryData
    let transports: [String]?

    var normalizedType: String {
        type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "public-key"
    }

    var normalizedTransports: [BrowserWebAuthnTransport] {
        (transports ?? []).compactMap(BrowserWebAuthnTransport.init(rawValue:))
    }

    var isPublicKeyCredential: Bool {
        normalizedType == "public-key"
    }
}

struct BrowserWebAuthnCreationRequest: Decodable {
    let mediation: String?
    let publicKey: BrowserWebAuthnCreationPublicKeyOptions
}

struct BrowserWebAuthnCreationPublicKeyOptions: Decodable {
    let challenge: BrowserWebAuthnBinaryData
    let rp: BrowserWebAuthnRelyingPartyDescriptor?
    let user: BrowserWebAuthnUserDescriptor
    let pubKeyCredParams: [BrowserWebAuthnCredentialParameter]
    let excludeCredentials: [BrowserWebAuthnCredentialDescriptor]?
    let authenticatorSelection: BrowserWebAuthnAuthenticatorSelection?
    let attestation: String?

    var normalizedAttestationPreference: String {
        switch attestation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "direct":
            return "direct"
        case "enterprise":
            return "enterprise"
        case "indirect":
            return "indirect"
        default:
            return "none"
        }
    }

    var requestedAlgorithms: [Int] {
        pubKeyCredParams
            .filter(\.isPublicKeyCredential)
            .map(\.alg)
    }
}

struct BrowserWebAuthnAssertionRequest: Decodable {
    let mediation: String?
    let publicKey: BrowserWebAuthnAssertionPublicKeyOptions
}

struct BrowserWebAuthnAssertionPublicKeyOptions: Decodable {
    let challenge: BrowserWebAuthnBinaryData
    let rpId: String?
    let allowCredentials: [BrowserWebAuthnCredentialDescriptor]?
    let userVerification: String?
    let extensions: BrowserWebAuthnAssertionExtensions?

    var normalizedUserVerificationPreference: String {
        switch userVerification?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "required":
            return "required"
        case "discouraged":
            return "discouraged"
        default:
            return "preferred"
        }
    }
}

struct BrowserWebAuthnRelyingPartyDescriptor: Decodable {
    let id: String?
    let name: String?
}

struct BrowserWebAuthnUserDescriptor: Decodable {
    let id: BrowserWebAuthnBinaryData
    let name: String?
    let displayName: String?
}

struct BrowserWebAuthnCredentialParameter: Decodable {
    let type: String?
    let alg: Int

    var normalizedType: String {
        type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "public-key"
    }

    var isPublicKeyCredential: Bool {
        normalizedType == "public-key"
    }
}

struct BrowserWebAuthnAuthenticatorSelection: Decodable {
    let authenticatorAttachment: String?
    let residentKey: String?
    let requireResidentKey: Bool?
    let userVerification: String?

    var attachment: String? {
        authenticatorAttachment?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var userVerificationPreference: String {
        switch userVerification?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "required":
            return "required"
        case "discouraged":
            return "discouraged"
        default:
            return "preferred"
        }
    }

    var residentKeyPreference: String {
        switch residentKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "required":
            return "required"
        case "preferred":
            return "preferred"
        case "discouraged":
            return "discouraged"
        default:
            return requireResidentKey == true ? "required" : "discouraged"
        }
    }
}

struct BrowserWebAuthnAssertionExtensions: Decodable {
    let appid: String?
}

enum BrowserWebAuthnTransport: String {
    case ble
    case hybrid
    case `internal`
    case nfc
    case usb
}

struct BrowserWebAuthnTransportSummary {
    let containsBluetooth: Bool
    let containsHybrid: Bool
    let containsInternal: Bool
    let containsSecurityKeyTransport: Bool
    let containsUnspecifiedTransport: Bool

    init(descriptors: [BrowserWebAuthnCredentialDescriptor]) {
        var containsBluetooth = false
        var containsHybrid = false
        var containsInternal = false
        var containsSecurityKeyTransport = false
        var containsUnspecifiedTransport = false

        for descriptor in descriptors where descriptor.isPublicKeyCredential {
            let transports = descriptor.normalizedTransports
            if transports.isEmpty {
                containsUnspecifiedTransport = true
                continue
            }

            for transport in transports {
                switch transport {
                case .ble:
                    containsBluetooth = true
                    containsSecurityKeyTransport = true
                case .hybrid:
                    containsHybrid = true
                case .internal:
                    containsInternal = true
                case .nfc, .usb:
                    containsSecurityKeyTransport = true
                }
            }
        }

        self.containsBluetooth = containsBluetooth
        self.containsHybrid = containsHybrid
        self.containsInternal = containsInternal
        self.containsSecurityKeyTransport = containsSecurityKeyTransport
        self.containsUnspecifiedTransport = containsUnspecifiedTransport
    }

    var allowsPlatformCredentials: Bool {
        containsInternal || containsHybrid || containsUnspecifiedTransport
    }

    var allowsSecurityKeyCredentials: Bool {
        containsSecurityKeyTransport || containsHybrid || containsUnspecifiedTransport
    }

    var needsBluetoothPreparation: Bool {
        containsBluetooth || containsHybrid
    }

    var shouldShowHybridTransport: Bool {
        containsHybrid || containsUnspecifiedTransport
    }

    var prefersSecurityKeysFirst: Bool {
        containsSecurityKeyTransport && !containsInternal && !containsHybrid && !containsUnspecifiedTransport
    }
}

private extension Data {
    init?(base64URLEncoded encoded: String) {
        let normalized = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - normalized.count % 4) % 4
        let padded = normalized + String(repeating: "=", count: paddingLength)
        self.init(base64Encoded: padded)
    }
}

private extension UInt8 {
    var isWebAuthnBase64URLByte: Bool {
        switch self {
        case 65 ... 90, 97 ... 122, 48 ... 57, 45, 95:
            return true
        default:
            return false
        }
    }
}

private extension Optional where Wrapped == String {
    func validateWebAuthnString(maxUTF8Bytes: Int) throws {
        guard let self else { return }
        guard self.utf8.count <= maxUTF8Bytes else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
    }
}

private extension BrowserWebAuthnBinaryData {
    func validateByteCount(_ range: ClosedRange<Int>) throws {
        guard range.contains(data.count) else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
    }
}

extension BrowserWebAuthnCreationRequest {
    func validateNativeRequestShape() throws {
        try mediation.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        try publicKey.validateNativeRequestShape()
    }
}

private extension BrowserWebAuthnCreationPublicKeyOptions {
    func validateNativeRequestShape() throws {
        try challenge.validateByteCount(BrowserWebAuthnRequestParser.challengeByteRange)
        try rp?.validateNativeRequestShape()
        try user.validateNativeRequestShape()
        guard pubKeyCredParams.count <= BrowserWebAuthnRequestParser.maximumCredentialParameters else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
        for parameter in pubKeyCredParams {
            try parameter.validateNativeRequestShape()
        }

        let excludedCredentials = excludeCredentials ?? []
        guard excludedCredentials.count <= BrowserWebAuthnRequestParser.maximumCredentialDescriptors else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
        for descriptor in excludedCredentials {
            try descriptor.validateNativeRequestShape()
        }

        try authenticatorSelection?.validateNativeRequestShape()
        try attestation.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
    }
}

extension BrowserWebAuthnAssertionRequest {
    func validateNativeRequestShape() throws {
        try mediation.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        try publicKey.validateNativeRequestShape()
    }
}

private extension BrowserWebAuthnAssertionPublicKeyOptions {
    func validateNativeRequestShape() throws {
        try challenge.validateByteCount(BrowserWebAuthnRequestParser.challengeByteRange)
        try rpId.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumRelyingPartyIDUTF8Bytes)
        try userVerification.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        let allowedCredentials = allowCredentials ?? []
        guard allowedCredentials.count <= BrowserWebAuthnRequestParser.maximumCredentialDescriptors else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
        for descriptor in allowedCredentials {
            try descriptor.validateNativeRequestShape()
        }
        try extensions?.validateNativeRequestShape()
    }
}

private extension BrowserWebAuthnCredentialDescriptor {
    func validateNativeRequestShape() throws {
        try type.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        try id.validateByteCount(BrowserWebAuthnRequestParser.credentialIDByteRange)
        let credentialTransports = transports ?? []
        guard credentialTransports.count <= BrowserWebAuthnRequestParser.maximumCredentialTransports else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
        for transport in credentialTransports {
            try Optional(transport).validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        }
    }
}

private extension BrowserWebAuthnRelyingPartyDescriptor {
    func validateNativeRequestShape() throws {
        try id.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumRelyingPartyIDUTF8Bytes)
        try name.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumDisplayStringUTF8Bytes)
    }
}

private extension BrowserWebAuthnUserDescriptor {
    func validateNativeRequestShape() throws {
        try id.validateByteCount(BrowserWebAuthnRequestParser.userIDByteRange)
        try name.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumDisplayStringUTF8Bytes)
        try displayName.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumDisplayStringUTF8Bytes)
    }
}

private extension BrowserWebAuthnCredentialParameter {
    func validateNativeRequestShape() throws {
        try type.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
    }
}

private extension BrowserWebAuthnAuthenticatorSelection {
    func validateNativeRequestShape() throws {
        try authenticatorAttachment.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        try residentKey.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
        try userVerification.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumShortStringUTF8Bytes)
    }
}

private extension BrowserWebAuthnAssertionExtensions {
    func validateNativeRequestShape() throws {
        try appid.validateWebAuthnString(maxUTF8Bytes: BrowserWebAuthnRequestParser.maximumAppIDUTF8Bytes)
    }
}
