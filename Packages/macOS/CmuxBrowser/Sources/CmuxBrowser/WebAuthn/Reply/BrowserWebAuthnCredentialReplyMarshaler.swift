public import AuthenticationServices
public import Foundation

/// Marshals `AuthenticationServices` credential results into the `[String: Any]`
/// wire dictionaries the WebAuthn page-world reply handler posts back to
/// JavaScript via `WKScriptMessageHandlerWithReply`.
public struct BrowserWebAuthnCredentialReplyMarshaler {
    public init() {}

    /// Builds the success reply for a completed authorization, dispatching on the
    /// concrete credential type to the matching registration or assertion shape.
    public func successCredentialReply(from credential: ASAuthorizationCredential) throws -> [String: Any] {
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

    /// Builds the `credential` payload for an attestation (registration) result.
    public func registrationReply(
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

    /// Builds the `credential` payload for an assertion (sign-in) result.
    public func assertionReply(
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

    /// The advertised `transports` strings for a security-key registration, empty
    /// before macOS 14.5 where the SDK does not expose them.
    public func securityKeyTransportValues(
        from registration: ASAuthorizationSecurityKeyPublicKeyCredentialRegistration
    ) -> [String] {
        guard #available(macOS 14.5, *) else { return [] }
        return registration.transports.map(\.rawValue)
    }

    /// The `appid` client-extension result for a security-key assertion, present
    /// only when the authenticator honored the legacy U2F AppID extension.
    public func appIDExtensionResults(
        from assertion: ASAuthorizationSecurityKeyPublicKeyCredentialAssertion
    ) -> [String: Any] {
        guard #available(macOS 14.5, *), assertion.appID else { return [:] }
        return ["appid": true]
    }
}
