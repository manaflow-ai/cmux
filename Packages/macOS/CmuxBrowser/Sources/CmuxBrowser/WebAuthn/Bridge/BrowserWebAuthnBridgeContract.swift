/// The native WebAuthn bridge contract shared by the page world and the native
/// coordinator: the `WKScriptMessageHandlerWithReply` name the injected script
/// posts to, plus the page-world JavaScript that overrides
/// `navigator.credentials.create`/`get`, serializes the public-key request
/// options, and routes the browser's WebAuthn ceremony to that handler. Native
/// results are marshalled back into JS objects matching the browser credential
/// shape.
public struct BrowserWebAuthnBridgeContract: Sendable {
    /// The message-handler name the page world posts bridge messages to.
    public let handlerName: String

    /// The page-world injector script, derived from `handlerName`. Installed once
    /// per web view; subsequent injections short-circuit via a window flag.
    public let scriptSource: String

    /// Builds a contract for the given message-handler name.
    public init(handlerName: String = "cmuxWebAuthn") {
        self.handlerName = handlerName
        self.scriptSource = #"""
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
    }

    /// The shared bridge contract used by the browser WebAuthn coordinator.
    public static let standard = BrowserWebAuthnBridgeContract()
}
