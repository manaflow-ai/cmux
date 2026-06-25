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
    static let contentWorld = WKContentWorld.world(name: "cmux.webauthn")

    private static let requestEventName = "__cmuxWebAuthnRequest"
    private static let acknowledgeEventName = "__cmuxWebAuthnRequestAcknowledged"
    private static let responseEventName = "__cmuxWebAuthnResponse"

    static let relayScriptSource: String = {
        let handlerName = BrowserWebAuthnBridgeContract.handlerName
        let requestEventName = BrowserWebAuthnBridgeContract.requestEventName
        let acknowledgeEventName = BrowserWebAuthnBridgeContract.acknowledgeEventName
        let responseEventName = BrowserWebAuthnBridgeContract.responseEventName
        return #"""
        (() => {
          if (window.__cmuxWebAuthnNativeRelayInstalled) {
            return true;
          }
          window.__cmuxWebAuthnNativeRelayInstalled = true;

          const handlerName = "\#(handlerName)";
          const requestEventName = "\#(requestEventName)";
          const acknowledgeEventName = "\#(acknowledgeEventName)";
          const responseEventName = "\#(responseEventName)";
          const maximumIDLength = 128;
          const maximumKindLength = 64;
          const maximumPayloadBytes = 512 * 1024;
          const textEncoder = typeof TextEncoder === "function" ? new TextEncoder() : null;

          const nativeHandler = () => {
            try {
              const handlers = window.webkit && window.webkit.messageHandlers;
              const handler = handlers && handlers[handlerName];
              return handler && typeof handler.postMessage === "function" ? handler : null;
            } catch (_) {
              return null;
            }
          };

          const utf8ByteLength = (value) =>
            textEncoder ? textEncoder.encode(value).byteLength : value.length;

          const errorReply = (name, message) => ({
            ok: false,
            error: {
              name: name || "UnknownError",
              message: message || "The passkey request failed.",
            },
          });

          const send = (eventName, detail) => {
            window.dispatchEvent(new CustomEvent(eventName, { detail }));
          };

          const validateMessage = (detail) => {
            if (!detail || typeof detail !== "object") {
              return { error: errorReply("TypeError", "Malformed browser passkey request.") };
            }

            const id = detail.id;
            const kind = detail.kind;
            if (
              typeof id !== "string" ||
              id.length === 0 ||
              id.length > maximumIDLength
            ) {
              return { error: errorReply("TypeError", "Malformed browser passkey request.") };
            }

            if (
              typeof kind !== "string" ||
              kind.length === 0 ||
              kind.length > maximumKindLength
            ) {
              return { id, error: errorReply("TypeError", "Malformed browser passkey request.") };
            }

            const hasPayload = Object.prototype.hasOwnProperty.call(detail, "payload");
            if (!hasPayload) {
              return { id, message: { kind } };
            }

            const payload = detail.payload;
            if (
              typeof payload !== "string" ||
              payload.length > maximumPayloadBytes ||
              utf8ByteLength(payload) > maximumPayloadBytes
            ) {
              return { id, error: errorReply("TypeError", "Malformed browser passkey request.") };
            }

            return { id, message: { kind, payload } };
          };

          window.addEventListener(requestEventName, (event) => {
            let validated;
            try {
              validated = validateMessage(event.detail);
            } catch (_) {
              return;
            }

            const id = validated.id;
            if (!id) {
              return;
            }
            send(acknowledgeEventName, { id });

            if (validated.error) {
              send(responseEventName, { id, reply: validated.error });
              return;
            }

            const handler = nativeHandler();
            if (!handler) {
              send(
                responseEventName,
                {
                  id,
                  reply: errorReply(
                    "NotSupportedError",
                    "Native passkey support is unavailable."
                  ),
                }
              );
              return;
            }

            handler
              .postMessage(validated.message)
              .then((reply) => {
                send(responseEventName, { id, reply });
              })
              .catch(() => {
                send(
                  responseEventName,
                  { id, reply: errorReply("UnknownError", "The passkey request failed.") }
                );
              });
          });

          return true;
        })();
        """#
    }()

    static let scriptSource: String = {
        let requestEventName = BrowserWebAuthnBridgeContract.requestEventName
        let acknowledgeEventName = BrowserWebAuthnBridgeContract.acknowledgeEventName
        let responseEventName = BrowserWebAuthnBridgeContract.responseEventName
        return #"""
        (() => {
          const currentFrameMayUseWebAuthn = () => {
            if (window.isSecureContext !== true) {
              return false;
            }
            return window.self === window.top;
          };

          if (!currentFrameMayUseWebAuthn()) {
            return false;
          }

          if (window.__cmuxWebAuthnBridgeInstalled) {
            return true;
          }
          window.__cmuxWebAuthnBridgeInstalled = true;

          const requestEventName = "\#(requestEventName)";
          const acknowledgeEventName = "\#(acknowledgeEventName)";
          const responseEventName = "\#(responseEventName)";
          const maximumPayloadBytes = 512 * 1024;
          const textEncoder = typeof TextEncoder === "function" ? new TextEncoder() : null;
          let nextRequestID = 0;

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

          const utf8ByteLength = (value) =>
            textEncoder ? textEncoder.encode(value).byteLength : value.length;

          const nextNativeRequestID = () => {
            nextRequestID += 1;
            return `cmux-webauthn-${Date.now()}-${nextRequestID}`;
          };

          const callNative = (kind, payload) => {
            if (
              typeof kind !== "string" ||
              kind.length === 0 ||
              kind.length > 64 ||
              (payload !== undefined &&
                (typeof payload !== "string" ||
                  payload.length > maximumPayloadBytes ||
                  utf8ByteLength(payload) > maximumPayloadBytes))
            ) {
              return Promise.reject(
                makeError("TypeError", "Malformed browser passkey request.")
              );
            }

            return new Promise((resolve, reject) => {
              const id = nextNativeRequestID();
              let acknowledged = false;
              let acknowledgeTimer = null;

              const cleanup = () => {
                if (acknowledgeTimer !== null) {
                  clearTimeout(acknowledgeTimer);
                }
                window.removeEventListener(acknowledgeEventName, handleAcknowledge);
                window.removeEventListener(responseEventName, handleResponse);
              };

              const handleAcknowledge = (event) => {
                if (!event.detail || event.detail.id !== id) {
                  return;
                }
                acknowledged = true;
                if (acknowledgeTimer !== null) {
                  clearTimeout(acknowledgeTimer);
                  acknowledgeTimer = null;
                }
              };

              const handleResponse = (event) => {
                if (!event.detail || event.detail.id !== id) {
                  return;
                }
                cleanup();
                try {
                  resolve(ensureReplySuccess(event.detail.reply));
                } catch (error) {
                  reject(error);
                }
              };

              window.addEventListener(acknowledgeEventName, handleAcknowledge);
              window.addEventListener(responseEventName, handleResponse);
              acknowledgeTimer = setTimeout(() => {
                if (!acknowledged) {
                  cleanup();
                  reject(
                    makeError("NotSupportedError", "Native passkey support is unavailable.")
                  );
                }
              }, 1000);

              const detail = payload === undefined ? { id, kind } : { id, kind, payload };
              window.dispatchEvent(new CustomEvent(requestEventName, { detail }));
            });
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

          const credentialsPatchTarget = () => {
            if (!navigator.credentials) {
              return null;
            }
            if (window.CredentialsContainer && window.CredentialsContainer.prototype) {
              return window.CredentialsContainer.prototype;
            }
            const prototype = Object.getPrototypeOf(navigator.credentials);
            return prototype && prototype !== Object.prototype ? prototype : navigator.credentials;
          };

          const credentialsTarget = credentialsPatchTarget();
          if (credentialsTarget) {
            const originalCreate = credentialsTarget.create;
            const originalGet = credentialsTarget.get;

            if (typeof originalCreate === "function") {
              Object.defineProperty(credentialsTarget, "create", {
                configurable: true,
                writable: true,
                value: function create(options) {
                  if (!options || !options.publicKey) {
                    return originalCreate.call(this, options);
                  }
                  return nativeCreateCredential(originalCreate, this, options);
                },
              });
            }

            if (typeof originalGet === "function") {
              Object.defineProperty(credentialsTarget, "get", {
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

@MainActor
private struct BrowserWebAuthnClientDataContext {
    let callerOrigin: BrowserWebAuthnSecurityOrigin
    let topLevelOrigin: BrowserWebAuthnSecurityOrigin?
    let crossOrigin: ASPublicKeyCredentialClientData.CrossOriginValue?

    static func resolve(for message: WKScriptMessage) throws -> Self {
        let callerOrigin = BrowserWebAuthnSecurityOrigin(origin: message.frameInfo.securityOrigin)
        let topLevelOrigin =
            message.webView?.url.flatMap(BrowserWebAuthnSecurityOrigin.init(url:)) ??
            (message.frameInfo.isMainFrame ? callerOrigin : nil)

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

    static func resolvePermitted(for message: WKScriptMessage) throws -> Self {
        let context = try resolve(for: message)
        try context.validatePermitted()
        return context
    }

    func validatePermitted() throws {
        guard let topLevelOrigin,
              callerOrigin.isPotentiallyTrustworthyWebAuthnOrigin,
              topLevelOrigin.isPotentiallyTrustworthyWebAuthnOrigin else {
            throw BrowserWebAuthnBridgeError.security("Passkey access requires a secure origin.")
        }
        guard crossOrigin == nil else {
            throw BrowserWebAuthnBridgeError.security("Passkey access is not available.")
        }
    }

    func clientData(challenge: Data) throws -> ASPublicKeyCredentialClientData {
        guard #available(macOS 13.5, *) else {
            throw BrowserWebAuthnBridgeError.notSupported("Native passkey support is unavailable.")
        }
        try validatePermitted()

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

    func resolveRelyingPartyIdentifier(_ explicitIdentifier: String?) throws -> String? {
        let requestedIdentifier =
            explicitIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? callerOrigin.host

        #if DEBUG
        cmuxDebugLog(
            "webauthn.resolveRP explicit=\(explicitIdentifier ?? "(nil)") " +
            "resolved=\(requestedIdentifier) callerHost=\(callerOrigin.host) " +
            "scopeOK=\(callerOrigin.isWithinRelyingPartyScope(requestedIdentifier)) " +
            "nativeOK=\(callerOrigin.permits(relyingPartyIdentifier: requestedIdentifier))"
        )
        #endif
        guard callerOrigin.isWithinRelyingPartyScope(requestedIdentifier) else {
            throw BrowserWebAuthnBridgeError.security("Passkey access is not available.")
        }
        guard callerOrigin.permits(relyingPartyIdentifier: requestedIdentifier) else {
            // Keep native parent-domain handling limited to explicitly reviewed
            // first-party RP IDs; WebKit owns all other public-suffix cases.
            return nil
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
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
            guard normalizedTransports.isEmpty else { return nil }
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

@MainActor
final class BrowserWebAuthnCoordinator: NSObject, WKScriptMessageHandlerWithReply {
    private weak var installedWebView: WKWebView?
    private var activeAuthorizationController: ASAuthorizationController?
    private var activeAuthorizationContinuation: CheckedContinuation<[String: Any], Error>?
    private var activePresentationWindow: NSWindow?

    override init() {
        super.init()
    }

    func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(
            forName: BrowserWebAuthnBridgeContract.handlerName,
            contentWorld: BrowserWebAuthnBridgeContract.contentWorld
        )
        controller.addScriptMessageHandler(
            self,
            contentWorld: BrowserWebAuthnBridgeContract.contentWorld,
            name: BrowserWebAuthnBridgeContract.handlerName
        )
        installedWebView = webView
    }

    func uninstall(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserWebAuthnBridgeContract.handlerName,
            contentWorld: BrowserWebAuthnBridgeContract.contentWorld
        )
        if installedWebView === webView {
            installedWebView = nil
        }
    }

    @MainActor
    func tearDown(from webView: WKWebView) {
        cancelActiveAuthorization()
        uninstall(from: webView)
    }

    @MainActor
    private func cancelActiveAuthorization() {
        let controller = activeAuthorizationController
        let continuation = activeAuthorizationContinuation
        activeAuthorizationController = nil
        activeAuthorizationContinuation = nil
        activePresentationWindow = nil
        controller?.delegate = nil
        controller?.presentationContextProvider = nil
        if #available(macOS 13.0, *) {
            controller?.cancel()
        }
        continuation?.resume(throwing: BrowserWebAuthnBridgeError.notAllowed("The passkey request failed."))
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
                cmuxDebugLog("webauthn.dispatch kind=\(envelope.kind.rawValue) frame=\(message.frameInfo.isMainFrame ? "main" : "sub") url=\(message.frameInfo.securityOrigin.host)")
                #endif
                switch envelope.kind {
                case .capabilities:
                    _ = try BrowserWebAuthnClientDataContext.resolvePermitted(for: message)
                    let callerMayPrompt = callerMayPromptForPlatformAuthorization(message)
                    let capReply = capabilityReply(
                        for: BrowserPasskeyAuthorizationGate.shared.currentAuthorizationState(),
                        bluetoothState: BrowserBluetoothAuthorizationGate.shared.currentState(),
                        callerMayPromptForPlatformAuthorization: callerMayPrompt
                    )
                    #if DEBUG
                    cmuxDebugLog("webauthn.capabilities reply=\(capReply)")
                    #endif
                    replyHandler(capReply, nil)
                case .createCredential:
                    let request = try BrowserWebAuthnRequestParser.decodePayload(
                        BrowserWebAuthnCreationRequest.self,
                        from: envelope
                    )
                    #if DEBUG
                    cmuxDebugLog(
                        "webauthn.createCredential hasRP=\((request.publicKey.rp?.id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? 1 : 0) " +
                        "hasUserName=\((request.publicKey.user.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? 1 : 0) " +
                        "userIDBytes=\(request.publicKey.user.id.data.count) " +
                        "attachment=\(request.publicKey.authenticatorSelection?.attachment ?? "(nil)") " +
                        "algorithmCount=\(request.publicKey.requestedAlgorithms.count)"
                    )
                    #endif
                    let reply = try await handleCreateCredential(request, message: message)
                    #if DEBUG
                    cmuxDebugLog("webauthn.createCredential reply.ok=\(reply["ok"] ?? "nil") hasCredential=\(reply["credential"] != nil) fallback=\(reply["useWebKitFallback"] ?? "nil")")
                    #endif
                    replyHandler(reply, nil)
                case .getCredential:
                    let request = try BrowserWebAuthnRequestParser.decodePayload(
                        BrowserWebAuthnAssertionRequest.self,
                        from: envelope
                    )
                    #if DEBUG
                    cmuxDebugLog(
                        "webauthn.getCredential hasRPID=\((request.publicKey.rpId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? 1 : 0) " +
                        "allowCredentials=\(request.publicKey.allowCredentials?.count ?? 0) " +
                        "mediation=\(request.mediation ?? "(nil)")"
                    )
                    #endif
                    let reply = try await handleGetCredential(request, message: message)
                    #if DEBUG
                    cmuxDebugLog("webauthn.getCredential reply.ok=\(reply["ok"] ?? "nil") hasCredential=\(reply["credential"] != nil) fallback=\(reply["useWebKitFallback"] ?? "nil")")
                    #endif
                    replyHandler(reply, nil)
                }
            } catch let error as BrowserWebAuthnBridgeError {
                #if DEBUG
                cmuxDebugLog("webauthn.error bridge: \(error.replyObject())")
                #endif
                replyHandler(error.replyObject(), nil)
            } catch {
                #if DEBUG
                cmuxDebugLog("webauthn.error unknown: \(error.localizedDescription)")
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
        cmuxDebugLog("webauthn.asAuth.didComplete credentialType=\(type(of: authorization.credential))")
        #endif
        do {
            finishAuthorization(
                with: .success(
                    try successCredentialReply(from: authorization.credential)
                )
            )
        } catch {
            #if DEBUG
            cmuxDebugLog("webauthn.asAuth.didComplete replyMarshalError=\(error)")
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
        cmuxDebugLog("webauthn.asAuth.didFail domain=\(nsError.domain) code=\(nsError.code)")
        #endif
        finishAuthorization(with: .failure(bridgeError(from: error)))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let anchor = activePresentationWindow ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
        #if DEBUG
        cmuxDebugLog("webauthn.asAuth.presentationAnchor hasTitle=\(anchor.title.isEmpty ? 0 : 1) isVisible=\(anchor.isVisible) isKey=\(anchor.isKeyWindow)")
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
        cmuxDebugLog(
            "webauthn.handleCreate BEGIN origin=\(message.frameInfo.securityOrigin.host) " +
            "webViewHost=\(message.webView?.url?.host ?? "(nil)") hasWebViewURL=\(message.webView?.url == nil ? 0 : 1)"
        )
        #endif
        let clientDataContext = try BrowserWebAuthnClientDataContext.resolvePermitted(for: message)
        guard let plan = try buildCreationPlan(request, clientDataContext: clientDataContext) else {
            #if DEBUG
            cmuxDebugLog("webauthn.handleCreate no plan — returning fallback")
            #endif
            return fallbackReply()
        }

        _ = try interactivePresentationWindow(for: message)
        let requests = try await authorizationRequests(for: plan, message: message)
        guard !requests.isEmpty else {
            #if DEBUG
            cmuxDebugLog("webauthn.handleCreate authorizationRequests empty — returning fallback")
            #endif
            return fallbackReply()
        }
        let presentationWindow = try interactivePresentationWindow(for: message)

        return try await performAuthorization(
            requests: requests,
            window: presentationWindow,
            prefersImmediatelyAvailableCredentials: plan.prefersImmediatelyAvailableCredentials
        )
    }

    func handleGetCredential(
        _ request: BrowserWebAuthnAssertionRequest,
        message: WKScriptMessage
    ) async throws -> [String: Any] {
        #if DEBUG
        cmuxDebugLog(
            "webauthn.handleGet BEGIN origin=\(message.frameInfo.securityOrigin.host) " +
            "webViewHost=\(message.webView?.url?.host ?? "(nil)") hasWebViewURL=\(message.webView?.url == nil ? 0 : 1)"
        )
        #endif
        let clientDataContext = try BrowserWebAuthnClientDataContext.resolvePermitted(for: message)
        guard let plan = try buildAssertionPlan(request, clientDataContext: clientDataContext) else {
            #if DEBUG
            cmuxDebugLog("webauthn.handleGet no plan — returning fallback")
            #endif
            return fallbackReply()
        }

        _ = try interactivePresentationWindow(for: message)
        let requests = try await authorizationRequests(for: plan, message: message)
        guard !requests.isEmpty else {
            #if DEBUG
            cmuxDebugLog("webauthn.handleGet authorizationRequests empty — returning fallback")
            #endif
            return fallbackReply()
        }
        let presentationWindow = try interactivePresentationWindow(for: message)

        return try await performAuthorization(
            requests: requests,
            window: presentationWindow,
            prefersImmediatelyAvailableCredentials: plan.prefersImmediatelyAvailableCredentials
        )
    }

    func interactivePresentationWindow(for message: WKScriptMessage) throws -> NSWindow {
        guard let webView = message.webView,
              installedWebView === webView,
              let window = browserInteractiveModalHostWindow(for: webView) else {
            #if DEBUG
            cmuxDebugLog(
                "webauthn.presentationWindow unavailable hasWebView=\(message.webView == nil ? 0 : 1) " +
                "hasWindow=\(message.webView?.window == nil ? 0 : 1) " +
                "isCurrent=\((message.webView != nil && installedWebView === message.webView) ? 1 : 0)"
            )
            #endif
            throw BrowserWebAuthnBridgeError.notAllowed("Passkey access is not available.")
        }
        return window
    }

    func authorizationRequests(
        for plan: BrowserWebAuthnNativeRequestPlan,
        message: WKScriptMessage
    ) async throws -> [ASAuthorizationRequest] {
        var includePlatformRequests = plan.hasPlatformRequests
        #if DEBUG
        cmuxDebugLog("webauthn.authRequests hasPlatform=\(plan.hasPlatformRequests) hasSecurityKey=\(plan.securityKeyRequests.count > 0) order=\(plan.order)")
        #endif

        if includePlatformRequests {
            let currentState = BrowserPasskeyAuthorizationGate.shared.currentAuthorizationState()
            #if DEBUG
            cmuxDebugLog("webauthn.authRequests passkeyAuthState=\(currentState.rawValue) callerMayPrompt=\(callerMayPromptForPlatformAuthorization(message))")
            #endif
            if currentState == .notDetermined && !callerMayPromptForPlatformAuthorization(message) {
                #if DEBUG
                cmuxDebugLog("webauthn.authRequests skipping platform: cross-origin subframe can't prompt")
                #endif
                includePlatformRequests = false
            } else {
                let authorizationState = await BrowserPasskeyAuthorizationGate.shared.authorizeIfNeeded()
                #if DEBUG
                cmuxDebugLog("webauthn.authRequests authorizeIfNeeded result=\(authorizationState.rawValue)")
                #endif
                if authorizationState != .authorized {
                    includePlatformRequests = false
                }
            }
        }

        let requests = plan.authorizationRequests(includePlatformRequests: includePlatformRequests)
        #if DEBUG
        cmuxDebugLog("webauthn.authRequests finalCount=\(requests.count) includePlatform=\(includePlatformRequests)")
        #endif
        guard !requests.isEmpty else {
            #if DEBUG
            cmuxDebugLog("webauthn.authRequests FAIL: no requests available, throwing notAllowed")
            #endif
            throw BrowserWebAuthnBridgeError.notAllowed("Passkey access was denied for this browser.")
        }

        if plan.needsBluetoothPreparation(includePlatformRequests: includePlatformRequests) {
            #if DEBUG
            cmuxDebugLog("webauthn.authRequests preparing bluetooth")
            #endif
            let btState = await BrowserBluetoothAuthorizationGate.shared.prepareIfNeeded()
            #if DEBUG
            cmuxDebugLog("webauthn.authRequests bluetooth result=\(btState)")
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
        cmuxDebugLog(
            "webauthn.performAuth requestCount=\(requests.count) hasWindow=\(window == nil ? 0 : 1) " +
            "hasWindowTitle=\((window?.title.isEmpty == false) ? 1 : 0) " +
            "prefersImmediate=\(prefersImmediatelyAvailableCredentials) " +
            "hasPendingContinuation=\(activeAuthorizationContinuation != nil)"
        )
        for (i, req) in requests.enumerated() {
            cmuxDebugLog("webauthn.performAuth request[\(i)]=\(type(of: req))")
        }
        #endif
        guard !requests.isEmpty else {
            throw BrowserWebAuthnBridgeError.notSupported("Native passkey support is unavailable.")
        }
        guard let window = browserInteractiveModalHostWindow(window) else {
            #if DEBUG
            cmuxDebugLog("webauthn.performAuth FAIL: no interactive window")
            #endif
            throw BrowserWebAuthnBridgeError.notAllowed("Passkey access is not available.")
        }
        guard activeAuthorizationContinuation == nil else {
            #if DEBUG
            cmuxDebugLog("webauthn.performAuth FAIL: ceremony already in progress")
            #endif
            throw BrowserWebAuthnBridgeError.notAllowed("The passkey request failed.")
        }

        #if DEBUG
        cmuxDebugLog("webauthn.performAuth launching ASAuthorizationController")
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
        try request.validateNativeRequestShape()

        guard let userName = request.publicKey.user.name, !userName.isEmpty else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }

        guard let relyingPartyIdentifier = try clientDataContext.resolveRelyingPartyIdentifier(
            request.publicKey.rp?.id
        ) else { return nil }
        let clientData = try clientDataContext.clientData(challenge: request.publicKey.challenge.data)
        let selection = request.publicKey.authenticatorSelection
        let attachment = selection?.attachment
        let requestedAlgorithms = request.publicKey.requestedAlgorithms

        guard !requestedAlgorithms.isEmpty else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }

        var platformRequests: [ASAuthorizationRequest] = []
        if attachment != "cross-platform",
           #available(macOS 13.5, *),
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
            cmuxDebugLog("webauthn.buildCreationPlan no requests built — returning nil")
            #endif
            return nil
        }

        #if DEBUG
        cmuxDebugLog("webauthn.buildCreationPlan rp=\(relyingPartyIdentifier) platform=\(platformRequests.count) securityKey=\(securityKeyRequests.count) attachment=\(attachment ?? "(nil)")")
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
        try request.validateNativeRequestShape()

        guard let relyingPartyIdentifier = try clientDataContext.resolveRelyingPartyIdentifier(
            request.publicKey.rpId
        ) else { return nil }
        if let appID = request.publicKey.extensions?.appid, !appID.isEmpty {
            // U2F AppID/facet validation is a separate browser trust boundary; keep it on WebKit.
            return nil
        }
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
                guard transports.contains(.internal) else {
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
            cmuxDebugLog("webauthn.buildAssertionPlan no requests built — returning nil")
            #endif
            return nil
        }

        let order: BrowserWebAuthnRequestOrder =
            transportSummary.prefersSecurityKeysFirst ? .securityKeyFirst : .platformFirst
        let needsBluetoothForPlatformRequests =
            allowCredentials.isEmpty ? true : transportSummary.shouldShowHybridTransport

        #if DEBUG
        cmuxDebugLog("webauthn.buildAssertionPlan rp=\(relyingPartyIdentifier) platform=\(platformRequests.count) securityKey=\(securityKeyRequests.count) allowCredentials=\(allowCredentials.count) mediation=\(request.mediation ?? "(nil)") hybridTransport=\(transportSummary.shouldShowHybridTransport)")
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
        let denied = state == .denied
        let platformRequestSupport = supportsPlatformCredentialRequests
        let deviceConfiguredForPasskeys = denied ? nil : self.deviceConfiguredForPasskeys()
        let platformPasskeyAvailability = browserWebAuthnAdvertisedPlatformPasskeyAvailability(
            authorizationState: state,
            deviceConfiguredForPasskeys: deviceConfiguredForPasskeys,
            callerMayPromptForPlatformAuthorization: callerMayPromptForPlatformAuthorization
        )
        #if DEBUG
        let authorized = state == .authorized
        let canPromptForAccess = state == .notDetermined && callerMayPromptForPlatformAuthorization
        let securityKeySupport = supportsSecurityKeyCredentialRequests
        cmuxDebugLog("webauthn.capability state=\(state.rawValue) authorized=\(authorized) denied=\(denied) canPrompt=\(canPromptForAccess) callerMayPrompt=\(callerMayPromptForPlatformAuthorization) platformSupport=\(platformRequestSupport) securityKeySupport=\(securityKeySupport) deviceConfigured=\(deviceConfiguredForPasskeys as Any) advertisedPlatform=\(platformPasskeyAvailability as Any) btAuth=\(bluetoothState.isAuthorized) btHybrid=\(bluetoothState.canUseHybridTransport)")
        #endif

        var payload: [String: Any] = [:]
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
