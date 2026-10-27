import CryptoKit
import Foundation

/// What cmux knows of the page a WEBAUTHN request names (``CEFPlatformPasskeys``).
nonisolated struct ChromiumPasskeyPage: Sendable, Equatable {
    /// The page's committed origin as Chromium serializes it, nil before a commit or for a scheme with no origin.
    var origin: String?
    /// Shown to the person: its pane shows it, in a visible window on the active Space (passkeys.md 3.4).
    var isVisible: Bool
    /// Under an agent lease (passkeys.md 3.5).
    var isAgentDriven: Bool
}

/// Why cmux refused a request: the reply is NULL, so Chromium answers NotAllowedError, and no sheet shows.
nonisolated enum ChromiumPasskeyRefusal: String, Error, Sendable {
    case malformed
    /// No CEF page of this runtime's host has the browser id.
    case unknownBrowser
    case agentLease
    case notVisible
    /// The SHA-256 of the client data is not the hash Chromium sent.
    case clientDataHash
    /// The client data's type is not the operation's.
    case clientDataType
    /// The client data's origin (or top origin) is not the page's, or not a secure one.
    case origin
    /// The rp id is neither a registrable suffix of the origin's host nor a related origin of it.
    case relyingParty
    /// The client data has members the system's own client data cannot have (``ChromiumClientData/hasOtherMembers``).
    case clientDataNotReproducible
    /// Something iCloud Keychain cannot do here (an algorithm other than ES256, a required large blob).
    case unsupported
    /// The page's pane has no window to anchor the sheet to (K10).
    case noWindow
    /// The system's client data differs from Chromium's, so the signature would not verify.
    case clientDataMismatch
    /// A create, refused before its sheet: the system saves the passkey before cmux can compare the client data
    /// bytes, and no run has proved them equal yet (``CEFPlatformPasskeys``).
    case createUnproven
}

/// The trust rules of the WEBAUTHN relay (plans/cmux-next/passkeys.md 3.9.3). cmux.app has the browser
/// passkey entitlement and can sign for any rp id, so a request runs only for a page cmux shows, with
/// client data whose origin is that page's, for an rp id the origin may use: the checks Chromium itself
/// makes before it asks an authenticator (content/browser/webauth/webauth_request_security_checker.cc,
/// `ValidateDomainAndRelyingPartyID`), made again in cmux, which does not trust the host's process.
nonisolated struct ChromiumPasskeyPolicy: Sendable {
    /// The request may run, or may run once the rp id's related origins list the caller's origin.
    enum Verdict: Equatable, Sendable {
        case allowed
        case needsRelatedOrigins(callerOrigin: String)
    }

    let publicSuffixes: PublicSuffixList

    /// The verdict on `request` from `page` (nil: no such page), with `clientData` parsed from its client data.
    func check(_ request: ChromiumPlatformPasskeyRequest, clientData: ChromiumClientData?,
               page: ChromiumPasskeyPage?) -> Result<Verdict, ChromiumPasskeyRefusal> {
        guard let page else { return .failure(.unknownBrowser) }
        guard !page.isAgentDriven else { return .failure(.agentLease) }
        guard let pageOrigin = page.origin, Self.isSecure(pageOrigin) else { return .failure(.origin) }
        guard request.operation != .list else { return .success(verdict(rpID: request.rpID, callerOrigin: pageOrigin)) }
        guard page.isVisible else { return .failure(.notVisible) }
        guard let clientData else { return .failure(.malformed) }
        guard Data(SHA256.hash(data: request.clientDataJSON)) == request.clientDataHash else { return .failure(.clientDataHash) }
        guard clientData.type == (request.operation == .create ? "webauthn.create" : "webauthn.get") else {
            return .failure(.clientDataType)
        }
        let framesPageOrigin = clientData.crossOrigin ? clientData.topOrigin == pageOrigin : clientData.origin == pageOrigin
        guard framesPageOrigin, clientData.crossOrigin || clientData.topOrigin == nil, Self.isSecure(clientData.origin) else {
            return .failure(.origin)
        }
        guard !clientData.hasOtherMembers else { return .failure(.clientDataNotReproducible) }
        if request.operation == .create {
            guard request.algorithms.isEmpty || request.algorithms.contains(ChromiumPlatformPasskeyRequest.es256),
                  !request.requiresLargeBlob else { return .failure(.unsupported) }
        }
        return .success(verdict(rpID: request.rpID, callerOrigin: clientData.origin))
    }

    /// Allowed when `rpID` is the caller's host or a registrable suffix of it (never a public suffix);
    /// otherwise only a related origin request can allow it.
    private func verdict(rpID: String, callerOrigin: String) -> Verdict {
        guard let host = URL(string: callerOrigin)?.host(percentEncoded: false)?.lowercased() else {
            return .needsRelatedOrigins(callerOrigin: callerOrigin)
        }
        if rpID == host, Self.isLocalhost(host) { return .allowed }
        let isSuffix = rpID == host || host.hasSuffix("." + rpID)
        return isSuffix && publicSuffixes.registrableDomain(of: rpID) != nil ? .allowed : .needsRelatedOrigins(callerOrigin: callerOrigin)
    }

    /// `url`'s origin as Chromium serializes a tuple origin (`url::Origin::Serialize`): scheme, host and a
    /// port other than the scheme's default; nil for a URL without one (about:, data:, file:).
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        let shownHost = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80
        guard let port = url.port, port != defaultPort else { return "\(scheme)://\(shownHost)" }
        return "\(scheme)://\(shownHost):\(port)"
    }

    /// WebAuthn's secure contexts: https, or http on localhost (Chromium's `IsOriginPotentiallyTrustworthy`).
    static func isSecure(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return url.scheme == "https" || (url.scheme == "http" && isLocalhost(host))
    }

    private static func isLocalhost(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost")
    }
}
