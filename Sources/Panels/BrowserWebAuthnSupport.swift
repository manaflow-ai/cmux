import AppKit
import AuthenticationServices
import Bonsplit
import CoreBluetooth
import Foundation
import ObjectiveC.runtime
import WebKit

/// Native WebAuthn bridge for `WKWebView`.
///
/// The page world overrides `navigator.credentials.create/get`, serializes the
/// public-key request options, and asks the native bridge to run the browser's
/// WebAuthn ceremony with AuthenticationServices. Native results are then
/// marshalled back into JS objects that match the browser credential shape.
enum BrowserWebAuthnBridgeContract {
    static let handlerName = "cmuxWebAuthn"

    static let scriptSource: String = {
        let handlerName = BrowserWebAuthnBridgeContract.handlerName
        return #"""
        (() => {
          if (window.__cmuxWebAuthnBridgeInstalled) {
            return true;
          }
          window.__cmuxWebAuthnBridgeInstalled = true;

          const handlerName = "\#(handlerName)";

          const nativeHandler = () => {
            try {
              const handlers = window.webkit && window.webkit.messageHandlers;
              const handler = handlers && handlers[handlerName];
              return handler && typeof handler.postMessage === "function" ? handler : null;
            } catch (_) {
              return null;
            }
          };

          const normalizedString = (value) =>
            typeof value === "string" ? value.trim().toLowerCase() : "";

          const bytesView = (value) => {
            if (value instanceof ArrayBuffer) {
              return new Uint8Array(value);
            }
            if (ArrayBuffer.isView(value)) {
              return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
            }
            return null;
          };

          const base64UrlEncode = (value) => {
            const bytes = bytesView(value);
            if (!bytes) {
              return null;
            }
            let binary = "";
            for (const byte of bytes) {
              binary += String.fromCharCode(byte);
            }
            return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
          };

          const base64UrlDecode = (value) => {
            if (typeof value !== "string") {
              return null;
            }
            const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
            const padded =
              normalized.length % 4 === 0
                ? normalized
                : normalized + "=".repeat(4 - (normalized.length % 4));
            const binary = atob(padded);
            const bytes = new Uint8Array(binary.length);
            for (let index = 0; index < binary.length; index += 1) {
              bytes[index] = binary.charCodeAt(index);
            }
            return bytes.buffer;
          };

          const makeError = (name, message) => {
            const safeName = name || "UnknownError";
            const safeMessage = message || "The passkey request failed.";
            if (safeName === "TypeError") {
              return new TypeError(safeMessage);
            }
            try {
              return new DOMException(safeMessage, safeName);
            } catch (_) {
              const error = new Error(safeMessage);
              error.name = safeName;
              return error;
            }
          };

          const ensureReplySuccess = (reply) => {
            if (reply && reply.ok === true) {
              return reply;
            }
            const error =
              reply && reply.error
                ? reply.error
                : { name: "UnknownError", message: "The passkey request failed." };
            throw makeError(error.name, error.message);
          };

          const callNative = (kind, payload) => {
            const handler = nativeHandler();
            if (!handler) {
              return Promise.reject(
                makeError("NotSupportedError", "Native passkey support is unavailable.")
              );
            }
            return handler.postMessage({ kind, payload }).then(ensureReplySuccess);
          };

          const serializeCredentialDescriptor = (descriptor) => {
            if (!descriptor) {
              return null;
            }
            const encodedID = base64UrlEncode(descriptor.id);
            if (!encodedID) {
              return null;
            }
            const transports = Array.isArray(descriptor.transports)
              ? descriptor.transports
                  .map((transport) => normalizedString(transport))
                  .filter(Boolean)
              : undefined;
            return {
              type: normalizedString(descriptor.type) || "public-key",
              id: encodedID,
              transports: transports && transports.length > 0 ? transports : undefined,
            };
          };

          const serializeCreateRequest = (options) => {
            const publicKey = (options && options.publicKey) || {};
            const rp = publicKey.rp || {};
            const user = publicKey.user || {};
            const selection = publicKey.authenticatorSelection || {};
            return {
              mediation: normalizedString(options && options.mediation) || undefined,
              publicKey: {
                challenge: base64UrlEncode(publicKey.challenge),
                rp: {
                  id: normalizedString(rp.id) || undefined,
                  name: typeof rp.name === "string" ? rp.name : undefined,
                },
                user: {
                  id: base64UrlEncode(user.id),
                  name: typeof user.name === "string" ? user.name : undefined,
                  displayName:
                    typeof user.displayName === "string" ? user.displayName : undefined,
                },
                pubKeyCredParams: Array.isArray(publicKey.pubKeyCredParams)
                  ? publicKey.pubKeyCredParams
                      .map((param) => ({
                        type: normalizedString(param && param.type) || "public-key",
                        alg: Number(param && param.alg),
                      }))
                      .filter((param) => Number.isFinite(param.alg))
                  : [],
                excludeCredentials: Array.isArray(publicKey.excludeCredentials)
                  ? publicKey.excludeCredentials
                      .map(serializeCredentialDescriptor)
                      .filter(Boolean)
                  : undefined,
                authenticatorSelection: {
                  authenticatorAttachment:
                    normalizedString(selection.authenticatorAttachment) || undefined,
                  residentKey: normalizedString(selection.residentKey) || undefined,
                  requireResidentKey:
                    typeof selection.requireResidentKey === "boolean"
                      ? selection.requireResidentKey
                      : undefined,
                  userVerification:
                    normalizedString(selection.userVerification) || undefined,
                },
                attestation: normalizedString(publicKey.attestation) || undefined,
              },
            };
          };

          const serializeGetRequest = (options) => {
            const publicKey = (options && options.publicKey) || {};
            const extensions = publicKey.extensions || {};
            return {
              mediation: normalizedString(options && options.mediation) || undefined,
              publicKey: {
                challenge: base64UrlEncode(publicKey.challenge),
                rpId: normalizedString(publicKey.rpId) || undefined,
                allowCredentials: Array.isArray(publicKey.allowCredentials)
                  ? publicKey.allowCredentials
                      .map(serializeCredentialDescriptor)
                      .filter(Boolean)
                  : undefined,
                userVerification:
                  normalizedString(publicKey.userVerification) || undefined,
                extensions: {
                  appid: typeof extensions.appid === "string" ? extensions.appid : undefined,
                },
              },
            };
          };

          const cloneExtensionResults = (value) => {
            if (!value || typeof value !== "object") {
              return {};
            }
            return JSON.parse(JSON.stringify(value));
          };

          const buildAttestationResponse = (serialized) => {
            const transports = Array.isArray(serialized.transports)
              ? [...serialized.transports]
              : [];
            const response = {
              clientDataJSON: base64UrlDecode(serialized.clientDataJSON),
              attestationObject: base64UrlDecode(serialized.attestationObject),
              getAuthenticatorData() {
                return null;
              },
              getPublicKey() {
                return null;
              },
              getPublicKeyAlgorithm() {
                return null;
              },
              getTransports() {
                return [...transports];
              },
              toJSON() {
                return {
                  clientDataJSON: serialized.clientDataJSON,
                  attestationObject: serialized.attestationObject,
                  transports: [...transports],
                };
              },
            };
            if (
              window.AuthenticatorAttestationResponse &&
              window.AuthenticatorAttestationResponse.prototype
            ) {
              Object.setPrototypeOf(
                response,
                window.AuthenticatorAttestationResponse.prototype
              );
            }
            return response;
          };

          const buildAssertionResponse = (serialized) => {
            const response = {
              clientDataJSON: base64UrlDecode(serialized.clientDataJSON),
              authenticatorData: base64UrlDecode(serialized.authenticatorData),
              signature: base64UrlDecode(serialized.signature),
              userHandle: serialized.userHandle
                ? base64UrlDecode(serialized.userHandle)
                : null,
              toJSON() {
                return {
                  clientDataJSON: serialized.clientDataJSON,
                  authenticatorData: serialized.authenticatorData,
                  signature: serialized.signature,
                  userHandle: serialized.userHandle || null,
                };
              },
            };
            if (
              window.AuthenticatorAssertionResponse &&
              window.AuthenticatorAssertionResponse.prototype
            ) {
              Object.setPrototypeOf(response, window.AuthenticatorAssertionResponse.prototype);
            }
            return response;
          };

          const hydrateCredential = (serialized) => {
            const extensions = cloneExtensionResults(serialized.clientExtensionResults);
            const response =
              serialized.responseKind === "attestation"
                ? buildAttestationResponse(serialized.response || {})
                : buildAssertionResponse(serialized.response || {});
            const credential = {
              type: "public-key",
              id: serialized.id,
              rawId: base64UrlDecode(serialized.rawId),
              authenticatorAttachment: serialized.authenticatorAttachment || null,
              response,
              getClientExtensionResults() {
                return cloneExtensionResults(extensions);
              },
              toJSON() {
                return {
                  id: serialized.id,
                  rawId: serialized.rawId,
                  type: "public-key",
                  authenticatorAttachment: serialized.authenticatorAttachment || null,
                  response: response.toJSON(),
                  clientExtensionResults: cloneExtensionResults(extensions),
                };
              },
            };
            if (window.PublicKeyCredential && window.PublicKeyCredential.prototype) {
              Object.setPrototypeOf(credential, window.PublicKeyCredential.prototype);
            }
            return credential;
          };

          const currentCapabilities = () =>
            callNative("capabilities").then((reply) => reply.capabilities || {});

          const nativeCreateCredential = (originalCreate, context, options) =>
            callNative("createCredential", JSON.stringify(serializeCreateRequest(options))).then(
              (reply) =>
                reply.useWebKitFallback === true
                  ? originalCreate.call(context, options)
                  : hydrateCredential(reply.credential)
            );

          const nativeGetCredential = (originalGet, context, options) =>
            callNative("getCredential", JSON.stringify(serializeGetRequest(options))).then(
              (reply) =>
                reply.useWebKitFallback === true
                  ? originalGet.call(context, options)
                  : hydrateCredential(reply.credential)
            );

          const capabilityFlag = (key, fallback) =>
            currentCapabilities()
              .then((capabilities) => {
                const value = capabilities[key];
                if (typeof value === "boolean") {
                  return value;
                }
                return typeof fallback === "function" ? fallback() : !!fallback;
              })
              .catch(() => (typeof fallback === "function" ? fallback() : !!fallback));

          if (window.CredentialsContainer && window.CredentialsContainer.prototype) {
            const prototype = window.CredentialsContainer.prototype;
            const originalCreate = prototype.create;
            const originalGet = prototype.get;

            Object.defineProperty(prototype, "create", {
              configurable: true,
              writable: true,
              value: function create(options) {
                if (!options || !options.publicKey) {
                  return originalCreate.call(this, options);
                }
                return nativeCreateCredential(originalCreate, this, options);
              },
            });

            Object.defineProperty(prototype, "get", {
              configurable: true,
              writable: true,
              value: function get(options) {
                if (!options || !options.publicKey) {
                  return originalGet.call(this, options);
                }
                return nativeGetCredential(originalGet, this, options);
              },
            });
          }

          if (window.PublicKeyCredential) {
            const originalUVPA =
              typeof window.PublicKeyCredential
                .isUserVerifyingPlatformAuthenticatorAvailable === "function"
                ? window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable.bind(
                    window.PublicKeyCredential
                  )
                : null;
            const originalConditional =
              typeof window.PublicKeyCredential.isConditionalMediationAvailable === "function"
                ? window.PublicKeyCredential.isConditionalMediationAvailable.bind(
                    window.PublicKeyCredential
                  )
                : null;

            window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable =
              function isUserVerifyingPlatformAuthenticatorAvailable() {
                return capabilityFlag(
                  "userVerifyingPlatformAuthenticatorAvailable",
                  originalUVPA || false
                );
              };

            if (originalConditional) {
              window.PublicKeyCredential.isConditionalMediationAvailable =
                function isConditionalMediationAvailable() {
                  return capabilityFlag(
                    "conditionalMediationAvailable",
                    originalConditional
                  );
                };
            }
          }

          return true;
        })();
        """#
    }()
}

private enum BrowserWebAuthnBridgeMessageKind: String {
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

private struct BrowserWebAuthnBridgeError: Error {
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

func browserWebAuthnAdvertisedPlatformPasskeyAvailability(
    authorizationState: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState,
    deviceConfiguredForPasskeys: Bool?,
    callerMayPromptForPlatformAuthorization: Bool
) -> Bool? {
    if authorizationState == .denied {
        return false
    }

    if authorizationState == .notDetermined && !callerMayPromptForPlatformAuthorization {
        return false
    }

    return deviceConfiguredForPasskeys
}

private struct BrowserWebAuthnMessageEnvelope {
    let kind: BrowserWebAuthnBridgeMessageKind
    let payloadJSON: String?
}

private enum BrowserWebAuthnRequestParser {
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

private struct BrowserWebAuthnBinaryData: Decodable {
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

private struct BrowserWebAuthnCredentialDescriptor: Decodable {
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

private struct BrowserWebAuthnCreationRequest: Decodable {
    let mediation: String?
    let publicKey: BrowserWebAuthnCreationPublicKeyOptions
}

private struct BrowserWebAuthnCreationPublicKeyOptions: Decodable {
    let challenge: BrowserWebAuthnBinaryData
    let rp: BrowserWebAuthnRelyingPartyDescriptor?
    let user: BrowserWebAuthnUserDescriptor
    let pubKeyCredParams: [BrowserWebAuthnCredentialParameter]
    let excludeCredentials: [BrowserWebAuthnCredentialDescriptor]?
    let authenticatorSelection: BrowserWebAuthnAuthenticatorSelection?
    let attestation: String?
}

private struct BrowserWebAuthnAssertionRequest: Decodable {
    let mediation: String?
    let publicKey: BrowserWebAuthnAssertionPublicKeyOptions
}

private struct BrowserWebAuthnAssertionPublicKeyOptions: Decodable {
    let challenge: BrowserWebAuthnBinaryData
    let rpId: String?
    let allowCredentials: [BrowserWebAuthnCredentialDescriptor]?
    let userVerification: String?
    let extensions: BrowserWebAuthnAssertionExtensions?
}

private struct BrowserWebAuthnRelyingPartyDescriptor: Decodable {
    let id: String?
    let name: String?
}

private struct BrowserWebAuthnUserDescriptor: Decodable {
    let id: BrowserWebAuthnBinaryData
    let name: String?
    let displayName: String?
}

private struct BrowserWebAuthnCredentialParameter: Decodable {
    let type: String?
    let alg: Int

    var normalizedType: String {
        type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "public-key"
    }

    var isPublicKeyCredential: Bool {
        normalizedType == "public-key"
    }
}

private struct BrowserWebAuthnAuthenticatorSelection: Decodable {
    let authenticatorAttachment: String?
    let residentKey: String?
    let requireResidentKey: Bool?
    let userVerification: String?
}

private struct BrowserWebAuthnAssertionExtensions: Decodable {
    let appid: String?
}

private enum BrowserWebAuthnTransport: String {
    case ble
    case hybrid
    case `internal`
    case nfc
    case usb
}

private struct BrowserWebAuthnTransportSummary {
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

private struct BrowserWebAuthnSecurityOrigin {
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
private struct BrowserWebAuthnClientDataContext {
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
        dlog("webauthn.resolveRP explicit=\(explicitIdentifier ?? "(nil)") resolved=\(requestedIdentifier) callerHost=\(callerOrigin.host) permitted=\(callerOrigin.permits(relyingPartyIdentifier: requestedIdentifier))")
        #endif
        guard callerOrigin.permits(relyingPartyIdentifier: requestedIdentifier) else {
            throw BrowserWebAuthnBridgeError.security("Passkey access is not available.")
        }

        return requestedIdentifier
    }
}

private enum BrowserWebAuthnRequestOrder {
    case platformFirst
    case securityKeyFirst
}

private struct BrowserWebAuthnNativeRequestPlan {
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

private extension Data {
    init?(base64URLEncoded encoded: String) {
        let normalized = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - normalized.count % 4) % 4
        let padded = normalized + String(repeating: "=", count: paddingLength)
        self.init(base64Encoded: padded)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension BrowserWebAuthnAuthenticatorSelection {
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

private extension BrowserWebAuthnAssertionPublicKeyOptions {
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

private extension BrowserWebAuthnCreationPublicKeyOptions {
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

private extension BrowserWebAuthnCredentialDescriptor {
    func platformDescriptor() -> ASAuthorizationPlatformPublicKeyCredentialDescriptor? {
        guard isPublicKeyCredential else { return nil }
        return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: id.data)
    }

    func securityKeyDescriptor() -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor? {
        guard isPublicKeyCredential else { return nil }

        let transports = normalizedTransports.compactMap { transport -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport? in
            switch transport {
            case .usb:
                return .init(rawValue: "usb")
            case .nfc:
                return .init(rawValue: "nfc")
            case .ble:
                return .init(rawValue: "ble")
            case .hybrid, .internal:
                return nil
            }
        }

        let descriptorTransports: [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport]
        if transports.isEmpty {
            descriptorTransports = [
                .init(rawValue: "usb"),
                .init(rawValue: "nfc"),
                .init(rawValue: "ble"),
            ]
        } else {
            descriptorTransports = transports
        }

        return ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
            credentialID: id.data,
            transports: descriptorTransports
        )
    }
}

private extension BrowserWebAuthnCredentialParameter {
    func securityKeyCredentialParameter() -> ASAuthorizationPublicKeyCredentialParameters? {
        guard isPublicKeyCredential else { return nil }
        return ASAuthorizationPublicKeyCredentialParameters(
            algorithm: ASCOSEAlgorithmIdentifier(alg)
        )
    }
}

private extension ASAuthorizationPublicKeyCredentialAttachment {
    var browserAttachmentValue: String {
        switch self {
        case .platform:
            return "platform"
        case .crossPlatform:
            return "cross-platform"
        @unknown default:
            return "cross-platform"
        }
    }
}

@MainActor
private struct BrowserBluetoothAuthorizationState {
    let authorization: CBManagerAuthorization
    let managerState: CBManagerState?

    var isAuthorized: Bool {
        authorization == .allowedAlways
    }

    var isPoweredOn: Bool? {
        guard let managerState else { return nil }
        return managerState == .poweredOn
    }

    var canUseHybridTransport: Bool {
        switch authorization {
        case .denied, .restricted:
            return false
        case .allowedAlways:
            guard let managerState else { return true }
            return managerState != .poweredOff
        case .notDetermined:
            return true
        @unknown default:
            return false
        }
    }
}

@MainActor
private final class BrowserBluetoothAuthorizationGate: NSObject, @preconcurrency CBCentralManagerDelegate {
    static let shared = BrowserBluetoothAuthorizationGate()

    private var centralManager: CBCentralManager?
    private var inFlightRequest: Task<BrowserBluetoothAuthorizationState, Never>?
    private var pendingContinuation: CheckedContinuation<BrowserBluetoothAuthorizationState, Never>?
    private var hasPrimedBluetoothActivity = false

    func currentState() -> BrowserBluetoothAuthorizationState {
        .init(
            authorization: CBCentralManager.authorization,
            managerState: centralManager?.state
        )
    }

    func prepareIfNeeded() async -> BrowserBluetoothAuthorizationState {
        let currentState = currentState()
        switch currentState.authorization {
        case .denied, .restricted:
            return currentState
        case .allowedAlways where currentState.managerState == .poweredOn:
            return currentState
        default:
            break
        }

        if let inFlightRequest {
            return await inFlightRequest.value
        }

        let request = Task { @MainActor in
            await withCheckedContinuation { continuation in
                pendingContinuation = continuation
                if let centralManager {
                    centralManagerDidUpdateState(centralManager)
                } else {
                    centralManager = CBCentralManager(
                        delegate: self,
                        queue: nil,
                        options: [CBCentralManagerOptionShowPowerAlertKey: true]
                    )
                }
            }
        }

        inFlightRequest = request
        let result = await request.value
        inFlightRequest = nil
        return result
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = BrowserBluetoothAuthorizationState(
            authorization: CBCentralManager.authorization,
            managerState: central.state
        )

        switch state.authorization {
        case .notDetermined:
            return
        case .allowedAlways:
            primeBluetoothActivityIfNeeded(with: central)
            finish(with: state)
        case .denied, .restricted:
            finish(with: state)
        @unknown default:
            finish(with: state)
        }
    }

    private func primeBluetoothActivityIfNeeded(with central: CBCentralManager) {
        guard !hasPrimedBluetoothActivity, central.state == .poweredOn else { return }
        hasPrimedBluetoothActivity = true
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        central.stopScan()
    }

    private func finish(with state: BrowserBluetoothAuthorizationState) {
        pendingContinuation?.resume(returning: state)
        pendingContinuation = nil
    }
}

@MainActor
private final class BrowserPasskeyAuthorizationGate {
    static let shared = BrowserPasskeyAuthorizationGate()

    private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    private var inFlightRequest: Task<ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState, Never>?

    func currentAuthorizationState() -> ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        manager.authorizationStateForPlatformCredentials
    }

    func authorizeIfNeeded() async -> ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        let currentState = manager.authorizationStateForPlatformCredentials
        guard currentState == .notDetermined else { return currentState }

        if let inFlightRequest {
            return await inFlightRequest.value
        }

        let request = Task { @MainActor [manager] in
            await withCheckedContinuation { continuation in
                manager.requestAuthorizationForPublicKeyCredentials { authorizationState in
                    continuation.resume(returning: authorizationState)
                }
            }
        }

        inFlightRequest = request
        let result = await request.value
        inFlightRequest = nil
        return result
    }
}

final class BrowserWebAuthnCoordinator: NSObject, WKScriptMessageHandlerWithReply {
    private var activeAuthorizationController: ASAuthorizationController?
    private var activeAuthorizationContinuation: CheckedContinuation<[String: Any], Error>?
    private var activePresentationWindow: NSWindow?

    override init() {
        super.init()
    }

    func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: BrowserWebAuthnBridgeContract.handlerName, contentWorld: .page)
        controller.addScriptMessageHandler(self, contentWorld: .page, name: BrowserWebAuthnBridgeContract.handlerName)
    }

    func uninstall(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserWebAuthnBridgeContract.handlerName,
            contentWorld: .page
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        Task { @MainActor in
            do {
                let envelope = try BrowserWebAuthnRequestParser.parseEnvelope(from: message.body)
                #if DEBUG
                dlog("webauthn.dispatch kind=\(envelope.kind.rawValue) frame=\(message.frameInfo.isMainFrame ? "main" : "sub") url=\(message.frameInfo.securityOrigin.host)")
                #endif
                switch envelope.kind {
                case .capabilities:
                    let callerMayPrompt = callerMayPromptForPlatformAuthorization(message)
                    let capReply = capabilityReply(
                        for: BrowserPasskeyAuthorizationGate.shared.currentAuthorizationState(),
                        bluetoothState: BrowserBluetoothAuthorizationGate.shared.currentState(),
                        callerMayPromptForPlatformAuthorization: callerMayPrompt
                    )
                    #if DEBUG
                    dlog("webauthn.capabilities reply=\(capReply)")
                    #endif
                    replyHandler(capReply, nil)
                case .createCredential:
                    let request = try BrowserWebAuthnRequestParser.decodePayload(
                        BrowserWebAuthnCreationRequest.self,
                        from: envelope
                    )
                    #if DEBUG
                    dlog("webauthn.createCredential rp=\(request.publicKey.rp?.id ?? "(nil)") user=\(request.publicKey.user.name ?? "(nil)") attachment=\(request.publicKey.authenticatorSelection?.attachment ?? "(nil)") algorithms=\(request.publicKey.requestedAlgorithms)")
                    #endif
                    let reply = try await handleCreateCredential(request, message: message)
                    #if DEBUG
                    dlog("webauthn.createCredential reply.ok=\(reply["ok"] ?? "nil") hasCredential=\(reply["credential"] != nil) fallback=\(reply["useWebKitFallback"] ?? "nil")")
                    #endif
                    replyHandler(reply, nil)
                case .getCredential:
                    let request = try BrowserWebAuthnRequestParser.decodePayload(
                        BrowserWebAuthnAssertionRequest.self,
                        from: envelope
                    )
                    #if DEBUG
                    dlog("webauthn.getCredential rpId=\(request.publicKey.rpId ?? "(nil)") allowCredentials=\(request.publicKey.allowCredentials?.count ?? 0) mediation=\(request.mediation ?? "(nil)")")
                    #endif
                    let reply = try await handleGetCredential(request, message: message)
                    #if DEBUG
                    dlog("webauthn.getCredential reply.ok=\(reply["ok"] ?? "nil") hasCredential=\(reply["credential"] != nil) fallback=\(reply["useWebKitFallback"] ?? "nil")")
                    #endif
                    replyHandler(reply, nil)
                }
            } catch let error as BrowserWebAuthnBridgeError {
                #if DEBUG
                dlog("webauthn.error bridge: \(error.replyObject())")
                #endif
                replyHandler(error.replyObject(), nil)
            } catch {
                #if DEBUG
                dlog("webauthn.error unknown: \(error.localizedDescription)")
                #endif
                replyHandler(BrowserWebAuthnBridgeError.unknown(error.localizedDescription).replyObject(), nil)
            }
        }
    }
}

@MainActor
extension BrowserWebAuthnCoordinator: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        #if DEBUG
        dlog("webauthn.asAuth.didComplete credentialType=\(type(of: authorization.credential))")
        #endif
        do {
            finishAuthorization(
                with: .success(
                    try successCredentialReply(from: authorization.credential)
                )
            )
        } catch {
            #if DEBUG
            dlog("webauthn.asAuth.didComplete replyMarshalError=\(error)")
            #endif
            finishAuthorization(with: .failure(error))
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        #if DEBUG
        let nsError = error as NSError
        dlog("webauthn.asAuth.didFail domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
        #endif
        finishAuthorization(with: .failure(bridgeError(from: error)))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let anchor = activePresentationWindow ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
        #if DEBUG
        dlog("webauthn.asAuth.presentationAnchor window=\(anchor.title) isVisible=\(anchor.isVisible) isKey=\(anchor.isKeyWindow)")
        #endif
        return anchor
    }
}

@MainActor
private extension BrowserWebAuthnCoordinator {
    enum BrowserWebAuthnAuthorizationErrorCode {
        // Keep these raw values in sync with AuthenticationServices/ASAuthorizationError.h
        // so we can handle newer cases even when the current Swift SDK omits the symbols.
        static let unknown = 1000
        static let canceled = 1001
        static let invalidResponse = 1002
        static let notHandled = 1003
        static let failed = 1004
        static let notInteractive = 1005
        static let matchedExcludedCredential = 1006
        static let credentialImport = 1007
        static let credentialExport = 1008
        static let preferSignInWithApple = 1009
        static let deviceNotConfiguredForPasskeyCreation = 1010
    }

    func handleCreateCredential(
        _ request: BrowserWebAuthnCreationRequest,
        message: WKScriptMessage
    ) async throws -> [String: Any] {
        #if DEBUG
        dlog("webauthn.handleCreate BEGIN origin=\(message.frameInfo.securityOrigin.host) webViewURL=\(message.webView?.url?.absoluteString ?? "(nil)")")
        #endif
        let clientDataContext = try BrowserWebAuthnClientDataContext.resolve(for: message)
        guard let plan = try buildCreationPlan(request, clientDataContext: clientDataContext) else {
            #if DEBUG
            dlog("webauthn.handleCreate no plan — returning fallback")
            #endif
            return fallbackReply()
        }

        let requests = try await authorizationRequests(for: plan, message: message)
        guard !requests.isEmpty else {
            #if DEBUG
            dlog("webauthn.handleCreate authorizationRequests empty — returning fallback")
            #endif
            return fallbackReply()
        }

        return try await performAuthorization(
            requests: requests,
            window: message.webView?.window,
            prefersImmediatelyAvailableCredentials: plan.prefersImmediatelyAvailableCredentials
        )
    }

    func handleGetCredential(
        _ request: BrowserWebAuthnAssertionRequest,
        message: WKScriptMessage
    ) async throws -> [String: Any] {
        #if DEBUG
        dlog("webauthn.handleGet BEGIN origin=\(message.frameInfo.securityOrigin.host) webViewURL=\(message.webView?.url?.absoluteString ?? "(nil)")")
        #endif
        let clientDataContext = try BrowserWebAuthnClientDataContext.resolve(for: message)
        guard let plan = try buildAssertionPlan(request, clientDataContext: clientDataContext) else {
            #if DEBUG
            dlog("webauthn.handleGet no plan — returning fallback")
            #endif
            return fallbackReply()
        }

        let requests = try await authorizationRequests(for: plan, message: message)
        guard !requests.isEmpty else {
            #if DEBUG
            dlog("webauthn.handleGet authorizationRequests empty — returning fallback")
            #endif
            return fallbackReply()
        }

        return try await performAuthorization(
            requests: requests,
            window: message.webView?.window,
            prefersImmediatelyAvailableCredentials: plan.prefersImmediatelyAvailableCredentials
        )
    }

    func authorizationRequests(
        for plan: BrowserWebAuthnNativeRequestPlan,
        message: WKScriptMessage
    ) async throws -> [ASAuthorizationRequest] {
        var includePlatformRequests = plan.hasPlatformRequests
        #if DEBUG
        dlog("webauthn.authRequests hasPlatform=\(plan.hasPlatformRequests) hasSecurityKey=\(plan.securityKeyRequests.count > 0) order=\(plan.order)")
        #endif

        if includePlatformRequests {
            let currentState = BrowserPasskeyAuthorizationGate.shared.currentAuthorizationState()
            #if DEBUG
            dlog("webauthn.authRequests passkeyAuthState=\(currentState.rawValue) callerMayPrompt=\(callerMayPromptForPlatformAuthorization(message))")
            #endif
            if currentState == .notDetermined && !callerMayPromptForPlatformAuthorization(message) {
                #if DEBUG
                dlog("webauthn.authRequests skipping platform: cross-origin subframe can't prompt")
                #endif
                includePlatformRequests = false
            } else {
                let authorizationState = await BrowserPasskeyAuthorizationGate.shared.authorizeIfNeeded()
                #if DEBUG
                dlog("webauthn.authRequests authorizeIfNeeded result=\(authorizationState.rawValue)")
                #endif
                if authorizationState != .authorized {
                    includePlatformRequests = false
                }
            }
        }

        let requests = plan.authorizationRequests(includePlatformRequests: includePlatformRequests)
        #if DEBUG
        dlog("webauthn.authRequests finalCount=\(requests.count) includePlatform=\(includePlatformRequests)")
        #endif
        guard !requests.isEmpty else {
            #if DEBUG
            dlog("webauthn.authRequests FAIL: no requests available, throwing notAllowed")
            #endif
            throw BrowserWebAuthnBridgeError.notAllowed("Passkey access was denied for this browser.")
        }

        if plan.needsBluetoothPreparation(includePlatformRequests: includePlatformRequests) {
            #if DEBUG
            dlog("webauthn.authRequests preparing bluetooth")
            #endif
            let btState = await BrowserBluetoothAuthorizationGate.shared.prepareIfNeeded()
            #if DEBUG
            dlog("webauthn.authRequests bluetooth result=\(btState)")
            #endif
        }

        return requests
    }

    func performAuthorization(
        requests: [ASAuthorizationRequest],
        window: NSWindow?,
        prefersImmediatelyAvailableCredentials: Bool
    ) async throws -> [String: Any] {
        #if DEBUG
        dlog("webauthn.performAuth requestCount=\(requests.count) window=\(window?.title ?? "(nil)") prefersImmediate=\(prefersImmediatelyAvailableCredentials) hasPendingContinuation=\(activeAuthorizationContinuation != nil)")
        for (i, req) in requests.enumerated() {
            dlog("webauthn.performAuth request[\(i)]=\(type(of: req))")
        }
        #endif
        guard !requests.isEmpty else {
            throw BrowserWebAuthnBridgeError.notSupported("Native passkey support is unavailable.")
        }
        guard let window else {
            #if DEBUG
            dlog("webauthn.performAuth FAIL: no window")
            #endif
            throw BrowserWebAuthnBridgeError.notSupported("Native passkey support is unavailable.")
        }
        guard activeAuthorizationContinuation == nil else {
            #if DEBUG
            dlog("webauthn.performAuth FAIL: ceremony already in progress")
            #endif
            throw BrowserWebAuthnBridgeError.notAllowed("The passkey request failed.")
        }

        #if DEBUG
        dlog("webauthn.performAuth launching ASAuthorizationController")
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            let controller = ASAuthorizationController(authorizationRequests: requests)
            activeAuthorizationController = controller
            activeAuthorizationContinuation = continuation
            activePresentationWindow = window
            controller.delegate = self
            controller.presentationContextProvider = self
            if prefersImmediatelyAvailableCredentials, #available(macOS 13.0, *) {
                controller.performRequests(options: .preferImmediatelyAvailableCredentials)
            } else {
                controller.performRequests()
            }
        }
    }

    func finishAuthorization(with result: Result<[String: Any], Error>) {
        let continuation = activeAuthorizationContinuation
        activeAuthorizationController = nil
        activeAuthorizationContinuation = nil
        activePresentationWindow = nil

        switch result {
        case .success(let reply):
            continuation?.resume(returning: reply)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    func buildCreationPlan(
        _ request: BrowserWebAuthnCreationRequest,
        clientDataContext: BrowserWebAuthnClientDataContext
    ) throws -> BrowserWebAuthnNativeRequestPlan? {
        guard let userName = request.publicKey.user.name, !userName.isEmpty else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }

        let relyingPartyIdentifier = try clientDataContext.resolveRelyingPartyIdentifier(
            request.publicKey.rp?.id
        )
        let clientData = try clientDataContext.clientData(challenge: request.publicKey.challenge.data)
        let selection = request.publicKey.authenticatorSelection
        let attachment = selection?.attachment
        let requestedAlgorithms = request.publicKey.requestedAlgorithms

        guard !requestedAlgorithms.isEmpty else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }

        var platformRequests: [ASAuthorizationRequest] = []
        if #available(macOS 13.5, *),
           requestedAlgorithms.contains(-7) {
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
                relyingPartyIdentifier: relyingPartyIdentifier
            )
            let platformRequest = provider.createCredentialRegistrationRequest(
                clientData: clientData,
                name: userName,
                userID: request.publicKey.user.id.data
            )
            platformRequest.displayName = request.publicKey.user.displayName ?? userName
            platformRequest.userVerificationPreference = .init(
                rawValue: selection?.userVerificationPreference ?? "preferred"
            )
            platformRequest.attestationPreference = .init(
                rawValue: request.publicKey.normalizedAttestationPreference
            )
            let excludedCredentials = (request.publicKey.excludeCredentials ?? [])
                .compactMap { $0.platformDescriptor() }
            if !excludedCredentials.isEmpty {
                platformRequest.excludedCredentials = excludedCredentials
            }
            platformRequest.shouldShowHybridTransport = attachment != "platform"
            platformRequests.append(platformRequest)
        }

        var securityKeyRequests: [ASAuthorizationRequest] = []
        if attachment != "platform",
           #available(macOS 14.4, *) {
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
                relyingPartyIdentifier: relyingPartyIdentifier
            )
            let securityKeyRequest = provider.createCredentialRegistrationRequest(
                clientData: clientData,
                displayName: request.publicKey.user.displayName ?? userName,
                name: userName,
                userID: request.publicKey.user.id.data
            )

            securityKeyRequest.credentialParameters = request.publicKey.pubKeyCredParams
                .compactMap { $0.securityKeyCredentialParameter() }
            if securityKeyRequest.credentialParameters.isEmpty {
                throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
            }

            securityKeyRequest.userVerificationPreference = .init(
                rawValue: selection?.userVerificationPreference ?? "preferred"
            )
            securityKeyRequest.residentKeyPreference = .init(
                rawValue: selection?.residentKeyPreference ?? "discouraged"
            )
            securityKeyRequest.attestationPreference = .init(
                rawValue: request.publicKey.normalizedAttestationPreference
            )
            let excludedCredentials = (request.publicKey.excludeCredentials ?? [])
                .compactMap { $0.securityKeyDescriptor() }
            if !excludedCredentials.isEmpty {
                securityKeyRequest.excludedCredentials = excludedCredentials
            }
            securityKeyRequests.append(securityKeyRequest)
        }

        guard !platformRequests.isEmpty || !securityKeyRequests.isEmpty else {
            #if DEBUG
            dlog("webauthn.buildCreationPlan no requests built — returning nil")
            #endif
            return nil
        }

        #if DEBUG
        dlog("webauthn.buildCreationPlan rp=\(relyingPartyIdentifier) platform=\(platformRequests.count) securityKey=\(securityKeyRequests.count) attachment=\(attachment ?? "(nil)")")
        #endif
        return .init(
            platformRequests: platformRequests,
            securityKeyRequests: securityKeyRequests,
            order: attachment == "cross-platform" ? .securityKeyFirst : .platformFirst,
            needsBluetoothForPlatformRequests: attachment != "platform",
            needsBluetoothForSecurityKeyRequests: false,
            prefersImmediatelyAvailableCredentials: false
        )
    }

    func buildAssertionPlan(
        _ request: BrowserWebAuthnAssertionRequest,
        clientDataContext: BrowserWebAuthnClientDataContext
    ) throws -> BrowserWebAuthnNativeRequestPlan? {
        let relyingPartyIdentifier = try clientDataContext.resolveRelyingPartyIdentifier(
            request.publicKey.rpId
        )
        let clientData = try clientDataContext.clientData(challenge: request.publicKey.challenge.data)
        let allowCredentials = (request.publicKey.allowCredentials ?? []).filter(\.isPublicKeyCredential)
        let transportSummary = BrowserWebAuthnTransportSummary(descriptors: allowCredentials)
        let userVerificationPreference = request.publicKey.normalizedUserVerificationPreference

        let includePlatformRequests =
            allowCredentials.isEmpty || transportSummary.allowsPlatformCredentials
        let includeSecurityKeyRequests =
            allowCredentials.isEmpty || transportSummary.allowsSecurityKeyCredentials

        var platformRequests: [ASAuthorizationRequest] = []
        if includePlatformRequests,
           #available(macOS 13.5, *) {
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
                relyingPartyIdentifier: relyingPartyIdentifier
            )
            let platformRequest = provider.createCredentialAssertionRequest(clientData: clientData)
            platformRequest.userVerificationPreference = .init(rawValue: userVerificationPreference)

            let allowedCredentials = allowCredentials.compactMap { descriptor -> ASAuthorizationPlatformPublicKeyCredentialDescriptor? in
                if descriptor.normalizedTransports.isEmpty {
                    return descriptor.platformDescriptor()
                }

                let transports = Set(descriptor.normalizedTransports)
                guard transports.contains(.internal) || transports.contains(.hybrid) else {
                    return nil
                }
                return descriptor.platformDescriptor()
            }
            if !allowedCredentials.isEmpty {
                platformRequest.allowedCredentials = allowedCredentials
            }
            platformRequest.shouldShowHybridTransport =
                allowCredentials.isEmpty ? true : transportSummary.shouldShowHybridTransport
            platformRequests.append(platformRequest)
        }

        var securityKeyRequests: [ASAuthorizationRequest] = []
        if includeSecurityKeyRequests,
           #available(macOS 14.4, *) {
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
                relyingPartyIdentifier: relyingPartyIdentifier
            )
            let securityKeyRequest = provider.createCredentialAssertionRequest(clientData: clientData)
            securityKeyRequest.userVerificationPreference = .init(rawValue: userVerificationPreference)
            let allowedCredentials = allowCredentials.compactMap { $0.securityKeyDescriptor() }
            if !allowedCredentials.isEmpty {
                securityKeyRequest.allowedCredentials = allowedCredentials
            }
            if #available(macOS 14.5, *),
               let appID = request.publicKey.extensions?.appid,
               !appID.isEmpty {
                securityKeyRequest.appID = appID
            }
            securityKeyRequests.append(securityKeyRequest)
        }

        guard !platformRequests.isEmpty || !securityKeyRequests.isEmpty else {
            #if DEBUG
            dlog("webauthn.buildAssertionPlan no requests built — returning nil")
            #endif
            return nil
        }

        let order: BrowserWebAuthnRequestOrder =
            transportSummary.prefersSecurityKeysFirst ? .securityKeyFirst : .platformFirst
        let needsBluetoothForPlatformRequests =
            allowCredentials.isEmpty ? true : transportSummary.shouldShowHybridTransport

        #if DEBUG
        dlog("webauthn.buildAssertionPlan rp=\(relyingPartyIdentifier) platform=\(platformRequests.count) securityKey=\(securityKeyRequests.count) allowCredentials=\(allowCredentials.count) mediation=\(request.mediation ?? "(nil)") hybridTransport=\(transportSummary.shouldShowHybridTransport)")
        #endif
        return .init(
            platformRequests: platformRequests,
            securityKeyRequests: securityKeyRequests,
            order: order,
            needsBluetoothForPlatformRequests: needsBluetoothForPlatformRequests,
            needsBluetoothForSecurityKeyRequests: transportSummary.containsBluetooth,
            prefersImmediatelyAvailableCredentials: request.mediation == "conditional"
        )
    }

    func successCredentialReply(from credential: ASAuthorizationCredential) throws -> [String: Any] {
        if let registration = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
            return [
                "ok": true,
                "credential": try registrationReply(
                    credentialID: registration.credentialID,
                    clientDataJSON: registration.rawClientDataJSON,
                    attestationObject: registration.rawAttestationObject,
                    attachment: registration.attachment.browserAttachmentValue,
                    transports: []
                ),
            ]
        }

        if let registration = credential as? ASAuthorizationSecurityKeyPublicKeyCredentialRegistration {
            return [
                "ok": true,
                "credential": try registrationReply(
                    credentialID: registration.credentialID,
                    clientDataJSON: registration.rawClientDataJSON,
                    attestationObject: registration.rawAttestationObject,
                    attachment: "cross-platform",
                    transports: securityKeyTransportValues(from: registration)
                ),
            ]
        }

        if let assertion = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            return [
                "ok": true,
                "credential": assertionReply(
                    credentialID: assertion.credentialID,
                    clientDataJSON: assertion.rawClientDataJSON,
                    authenticatorData: assertion.rawAuthenticatorData,
                    signature: assertion.signature,
                    userHandle: assertion.userID,
                    attachment: assertion.attachment.browserAttachmentValue,
                    clientExtensionResults: [:]
                ),
            ]
        }

        if let assertion = credential as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion {
            return [
                "ok": true,
                "credential": assertionReply(
                    credentialID: assertion.credentialID,
                    clientDataJSON: assertion.rawClientDataJSON,
                    authenticatorData: assertion.rawAuthenticatorData,
                    signature: assertion.signature,
                    userHandle: assertion.userID,
                    attachment: "cross-platform",
                    clientExtensionResults: appIDExtensionResults(from: assertion)
                ),
            ]
        }

        throw BrowserWebAuthnBridgeError.unknown("The passkey request failed.")
    }

    func registrationReply(
        credentialID: Data,
        clientDataJSON: Data,
        attestationObject: Data?,
        attachment: String,
        transports: [String]
    ) throws -> [String: Any] {
        guard let attestationObject else {
            throw BrowserWebAuthnBridgeError.unknown("The passkey request failed.")
        }

        var credential: [String: Any] = [
            "type": "public-key",
            "id": credentialID.base64URLEncodedString(),
            "rawId": credentialID.base64URLEncodedString(),
            "authenticatorAttachment": attachment,
            "responseKind": "attestation",
            "response": [
                "clientDataJSON": clientDataJSON.base64URLEncodedString(),
                "attestationObject": attestationObject.base64URLEncodedString(),
                "transports": transports,
            ],
            "clientExtensionResults": [:],
        ]

        if !transports.isEmpty {
            credential["transports"] = transports
        }

        return credential
    }

    func assertionReply(
        credentialID: Data,
        clientDataJSON: Data,
        authenticatorData: Data,
        signature: Data,
        userHandle: Data,
        attachment: String,
        clientExtensionResults: [String: Any]
    ) -> [String: Any] {
        var response: [String: Any] = [
            "clientDataJSON": clientDataJSON.base64URLEncodedString(),
            "authenticatorData": authenticatorData.base64URLEncodedString(),
            "signature": signature.base64URLEncodedString(),
        ]

        if !userHandle.isEmpty {
            response["userHandle"] = userHandle.base64URLEncodedString()
        }

        return [
            "type": "public-key",
            "id": credentialID.base64URLEncodedString(),
            "rawId": credentialID.base64URLEncodedString(),
            "authenticatorAttachment": attachment,
            "responseKind": "assertion",
            "response": response,
            "clientExtensionResults": clientExtensionResults,
        ]
    }

    func securityKeyTransportValues(
        from registration: ASAuthorizationSecurityKeyPublicKeyCredentialRegistration
    ) -> [String] {
        guard #available(macOS 14.5, *) else { return [] }
        return registration.transports.map(\.rawValue)
    }

    func appIDExtensionResults(
        from assertion: ASAuthorizationSecurityKeyPublicKeyCredentialAssertion
    ) -> [String: Any] {
        guard #available(macOS 14.5, *), assertion.appID else { return [:] }
        return ["appid": true]
    }

    func bridgeError(from error: Error) -> BrowserWebAuthnBridgeError {
        if let bridgeError = error as? BrowserWebAuthnBridgeError {
            return bridgeError
        }

        let nsError = error as NSError
        guard nsError.domain == ASAuthorizationErrorDomain else {
            return .unknown("The passkey request failed.")
        }

        switch nsError.code {
        case BrowserWebAuthnAuthorizationErrorCode.matchedExcludedCredential:
            return .invalidState("The passkey request failed.")
        case BrowserWebAuthnAuthorizationErrorCode.canceled,
             BrowserWebAuthnAuthorizationErrorCode.failed,
             BrowserWebAuthnAuthorizationErrorCode.invalidResponse,
             BrowserWebAuthnAuthorizationErrorCode.notHandled,
             BrowserWebAuthnAuthorizationErrorCode.notInteractive,
             BrowserWebAuthnAuthorizationErrorCode.credentialExport,
             BrowserWebAuthnAuthorizationErrorCode.credentialImport,
             BrowserWebAuthnAuthorizationErrorCode.deviceNotConfiguredForPasskeyCreation,
             BrowserWebAuthnAuthorizationErrorCode.preferSignInWithApple:
            return .notAllowed("The passkey request failed.")
        case BrowserWebAuthnAuthorizationErrorCode.unknown:
            return .unknown("The passkey request failed.")
        default:
            return .unknown("The passkey request failed.")
        }
    }

    func capabilityReply(
        for state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState,
        bluetoothState: BrowserBluetoothAuthorizationState,
        callerMayPromptForPlatformAuthorization: Bool
    ) -> [String: Any] {
        [
            "ok": true,
            "capabilities": capabilityPayload(
                for: state,
                bluetoothState: bluetoothState,
                callerMayPromptForPlatformAuthorization: callerMayPromptForPlatformAuthorization
            ),
        ]
    }

    func capabilityPayload(
        for state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState,
        bluetoothState: BrowserBluetoothAuthorizationState,
        callerMayPromptForPlatformAuthorization: Bool
    ) -> [String: Any] {
        let authorized = state == .authorized
        let denied = state == .denied
        let canPromptForAccess = state == .notDetermined && callerMayPromptForPlatformAuthorization
        let platformRequestSupport = supportsPlatformCredentialRequests
        let securityKeySupport = supportsSecurityKeyCredentialRequests
        let deviceConfiguredForPasskeys = denied ? nil : self.deviceConfiguredForPasskeys()
        let platformPasskeyAvailability = browserWebAuthnAdvertisedPlatformPasskeyAvailability(
            authorizationState: state,
            deviceConfiguredForPasskeys: deviceConfiguredForPasskeys,
            callerMayPromptForPlatformAuthorization: callerMayPromptForPlatformAuthorization
        )
        #if DEBUG
        dlog("webauthn.capability state=\(state.rawValue) authorized=\(authorized) denied=\(denied) canPrompt=\(canPromptForAccess) callerMayPrompt=\(callerMayPromptForPlatformAuthorization) platformSupport=\(platformRequestSupport) securityKeySupport=\(securityKeySupport) deviceConfigured=\(deviceConfiguredForPasskeys as Any) advertisedPlatform=\(platformPasskeyAvailability as Any) btAuth=\(bluetoothState.isAuthorized) btHybrid=\(bluetoothState.canUseHybridTransport)")
        #endif

        var payload: [String: Any] = [
            "authorized": authorized,
            "denied": denied,
            "canPromptForAccess": canPromptForAccess,
            "bluetoothAuthorized": bluetoothState.isAuthorized,
            "hybridTransportAvailable": platformRequestSupport && bluetoothState.canUseHybridTransport,
            "securityKeysAvailable": securityKeySupport,
        ]

        if let bluetoothPoweredOn = bluetoothState.isPoweredOn {
            payload["bluetoothPoweredOn"] = bluetoothPoweredOn
        }

        if platformRequestSupport,
           let platformPasskeyAvailability {
            payload["userVerifyingPlatformAuthenticatorAvailable"] = platformPasskeyAvailability
            payload["conditionalMediationAvailable"] = platformPasskeyAvailability
        }

        return payload
    }

    var supportsPlatformCredentialRequests: Bool {
        if #available(macOS 13.5, *) {
            return true
        }
        return false
    }

    var supportsSecurityKeyCredentialRequests: Bool {
        if #available(macOS 14.4, *) {
            return true
        }
        return false
    }

    func deviceConfiguredForPasskeys() -> Bool? {
        let selector = NSSelectorFromString("isDeviceConfiguredForPasskeys")
        let managerClass: AnyClass = ASAuthorizationWebBrowserPublicKeyCredentialManager.self

        guard let metaClass = object_getClass(managerClass),
              class_respondsToSelector(metaClass, selector),
              let method = class_getClassMethod(managerClass, selector) else {
            return nil
        }

        typealias Getter = @convention(c) (AnyClass, Selector) -> Bool
        let implementation = method_getImplementation(method)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(managerClass, selector)
    }

    func fallbackReply() -> [String: Any] {
        [
            "ok": true,
            "useWebKitFallback": true,
        ]
    }

    func callerMayPromptForPlatformAuthorization(_ message: WKScriptMessage) -> Bool {
        if message.frameInfo.isMainFrame {
            return true
        }

        guard let webView = message.webView,
              let topLevelURL = webView.url,
              let topLevelOrigin = BrowserWebAuthnSecurityOrigin(url: topLevelURL) else {
            return false
        }

        return topLevelOrigin.matches(message.frameInfo.securityOrigin)
    }
}
