public import AuthenticationServices
public import Foundation
public import WebKit
#if DEBUG
internal import CMUXDebugLog
#endif

/// The client-data context for a single WebAuthn ceremony: the caller and
/// top-level origins, the cross-origin disposition, and the relying-party gate.
@MainActor
public struct BrowserWebAuthnClientDataContext {
    let callerOrigin: BrowserWebAuthnSecurityOrigin
    let topLevelOrigin: BrowserWebAuthnSecurityOrigin?
    let crossOrigin: ASPublicKeyCredentialClientData.CrossOriginValue?

    /// Resolves the client-data context from an incoming bridge message,
    /// computing the cross-origin disposition from the frame hierarchy.
    public static func resolve(for message: WKScriptMessage) throws -> Self {
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

    /// Builds the `ASPublicKeyCredentialClientData` for the given challenge.
    public func clientData(challenge: Data) throws -> ASPublicKeyCredentialClientData {
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

    /// Resolves and authorizes the relying-party identifier for this caller,
    /// defaulting to the caller's host and rejecting identifiers it cannot act for.
    public func resolveRelyingPartyIdentifier(_ explicitIdentifier: String?) throws -> String {
        let requestedIdentifier =
            explicitIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? callerOrigin.host

        #if DEBUG
        CMUXDebugLog.logDebugEvent("webauthn.resolveRP explicit=\(explicitIdentifier ?? "(nil)") resolved=\(requestedIdentifier) callerHost=\(callerOrigin.host) permitted=\(callerOrigin.permits(relyingPartyIdentifier: requestedIdentifier))")
        #endif
        guard callerOrigin.permits(relyingPartyIdentifier: requestedIdentifier) else {
            throw BrowserWebAuthnBridgeError.security("Passkey access is not available.")
        }

        return requestedIdentifier
    }
}
