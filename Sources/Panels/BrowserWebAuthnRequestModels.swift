import AppKit
import AuthenticationServices
import Bonsplit
import CoreBluetooth
import Foundation
import ObjectiveC.runtime
import WebKit


// MARK: - WebAuthn Bridge Request Models & Parsing
enum BrowserWebAuthnBridgeMessageKind: String {
    case capabilities
    case createCredential
    case getCredential
}

enum BrowserWebAuthnErrorName: String {
    case invalidState = "InvalidStateError"
    case notAllowed = "NotAllowedError"
    case notSupported = "NotSupportedError"
    case security = "SecurityError"
    case type = "TypeError"
    case unknown = "UnknownError"
}

struct BrowserWebAuthnBridgeError: Error {
    let name: BrowserWebAuthnErrorName
    let message: String

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
    let payloadJSON: String?
}

enum BrowserWebAuthnRequestParser {
    static func parseEnvelope(from body: Any) throws -> BrowserWebAuthnMessageEnvelope {
        guard let root = body as? [String: Any],
              let rawKind = root["kind"] as? String,
              let kind = BrowserWebAuthnBridgeMessageKind(rawValue: rawKind) else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }

        return .init(kind: kind, payloadJSON: root["payload"] as? String)
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
        guard let data = Data(base64URLEncoded: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid base64url-encoded WebAuthn binary value."
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
    private let containsHybrid: Bool
    private let containsInternal: Bool
    private let containsSecurityKeyTransport: Bool
    private let containsUnspecifiedTransport: Bool

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

    var prefersSecurityKeysFirst: Bool {
        containsSecurityKeyTransport &&
            !containsInternal &&
            !containsHybrid &&
            !containsUnspecifiedTransport
    }

    var shouldShowHybridTransport: Bool {
        containsHybrid || containsUnspecifiedTransport
    }
}

struct BrowserWebAuthnSecurityOrigin {
    let scheme: String
    let host: String
    let port: Int

    init(origin: WKSecurityOrigin) {
        scheme = origin.protocol.lowercased()
        host = origin.host.lowercased()
        port = Self.normalizedPort(scheme: scheme, port: origin.port)
    }

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return nil
        }

        self.scheme = scheme
        self.host = host
        port = Self.normalizedPort(scheme: scheme, port: url.port)
    }

    var serializedString: String {
        let isDefaultHTTPS = scheme == "https" && port == 443
        let isDefaultHTTP = scheme == "http" && port == 80
        if isDefaultHTTPS || isDefaultHTTP || port < 0 {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    func matches(_ origin: WKSecurityOrigin) -> Bool {
        let other = Self(origin: origin)
        return scheme == other.scheme && host == other.host && port == other.port
    }

    func permits(relyingPartyIdentifier: String) -> Bool {
        let normalizedIdentifier = relyingPartyIdentifier.lowercased()
        guard !normalizedIdentifier.isEmpty else { return false }
        return host == normalizedIdentifier || host.hasSuffix(".\(normalizedIdentifier)")
    }

    private static func normalizedPort(scheme: String, port: Int?) -> Int {
        if let port, port > 0 {
            return port
        }

        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return -1
        }
    }
}

@MainActor
struct BrowserWebAuthnClientDataContext {
    let callerOrigin: BrowserWebAuthnSecurityOrigin
    let topLevelOrigin: BrowserWebAuthnSecurityOrigin?
    let crossOrigin: ASPublicKeyCredentialClientData.CrossOriginValue?

    static func resolve(for message: WKScriptMessage) throws -> Self {
        let callerOrigin = BrowserWebAuthnSecurityOrigin(origin: message.frameInfo.securityOrigin)
        let topLevelOrigin = message.webView?.url.flatMap(BrowserWebAuthnSecurityOrigin.init(url:))

        let crossOrigin: ASPublicKeyCredentialClientData.CrossOriginValue?
        if message.frameInfo.isMainFrame {
            crossOrigin = nil
        } else if let topLevelOrigin, topLevelOrigin.matches(message.frameInfo.securityOrigin) {
            crossOrigin = .sameOriginWithAncestors
        } else {
            crossOrigin = .crossOrigin
        }

        return .init(
            callerOrigin: callerOrigin,
            topLevelOrigin: topLevelOrigin,
            crossOrigin: crossOrigin
        )
    }

    func clientData(challenge: Data) throws -> ASPublicKeyCredentialClientData {
        guard #available(macOS 13.5, *) else {
            throw BrowserWebAuthnBridgeError.notSupported("Native passkey support is unavailable.")
        }

        let topOrigin: String?
        if let topLevelOrigin, topLevelOrigin.serializedString != callerOrigin.serializedString {
            topOrigin = topLevelOrigin.serializedString
        } else {
            topOrigin = nil
        }

        return ASPublicKeyCredentialClientData(
            challenge: challenge,
            origin: callerOrigin.serializedString,
            topOrigin: topOrigin,
            crossOrigin: crossOrigin
        )
    }

    func resolveRelyingPartyIdentifier(_ explicitIdentifier: String?) throws -> String {
        let requestedIdentifier =
            explicitIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? callerOrigin.host

        #if DEBUG
        cmuxDebugLog("webauthn.resolveRP explicit=\(explicitIdentifier ?? "(nil)") resolved=\(requestedIdentifier) callerHost=\(callerOrigin.host) permitted=\(callerOrigin.permits(relyingPartyIdentifier: requestedIdentifier))")
        #endif
        guard callerOrigin.permits(relyingPartyIdentifier: requestedIdentifier) else {
            throw BrowserWebAuthnBridgeError.security("Passkey access is not available.")
        }

        return requestedIdentifier
    }
}

enum BrowserWebAuthnRequestOrder {
    case platformFirst
    case securityKeyFirst
}

struct BrowserWebAuthnNativeRequestPlan {
    let platformRequests: [ASAuthorizationRequest]
    let securityKeyRequests: [ASAuthorizationRequest]
    let order: BrowserWebAuthnRequestOrder
    let needsBluetoothForPlatformRequests: Bool
    let needsBluetoothForSecurityKeyRequests: Bool
    let prefersImmediatelyAvailableCredentials: Bool

    var hasPlatformRequests: Bool {
        !platformRequests.isEmpty
    }

    var hasSecurityKeyRequests: Bool {
        !securityKeyRequests.isEmpty
    }

    func authorizationRequests(includePlatformRequests: Bool) -> [ASAuthorizationRequest] {
        switch order {
        case .platformFirst:
            return (includePlatformRequests ? platformRequests : []) + securityKeyRequests
        case .securityKeyFirst:
            return securityKeyRequests + (includePlatformRequests ? platformRequests : [])
        }
    }

    func needsBluetoothPreparation(includePlatformRequests: Bool) -> Bool {
        (includePlatformRequests && needsBluetoothForPlatformRequests) ||
            (hasSecurityKeyRequests && needsBluetoothForSecurityKeyRequests)
    }
}

