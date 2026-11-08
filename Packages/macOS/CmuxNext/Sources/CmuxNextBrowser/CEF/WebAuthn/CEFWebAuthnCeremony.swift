import AppKit
import AuthenticationServices

/// Runs one delegated WebAuthn request with AuthenticationServices' browser API: the platform
/// provider (iCloud Keychain and other passkey providers, a phone over hybrid) and the security key
/// provider, each with the browser form of the request (`ASPublicKeyCredentialClientData` from the
/// page's origin and challenge), so the system builds the clientDataJSON the page's server checks.
/// The system sheet anchors to the visible cmux window that asked the person first
/// (`CEFWebAuthnPrompts`). Needs the `com.apple.developer.web-browser.public-key-credential`
/// entitlement (signed builds); without it the platform provider is left out.
@MainActor
final class CEFWebAuthnCeremony: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    enum Outcome: Equatable {
        case credential(json: String)
        /// A DOMException name the fork allows, and a message for the page.
        case failure(name: String, message: String)
    }

    private let window: NSWindow
    private let request: CEFWebAuthnRequest
    private var controller: ASAuthorizationController?
    private var completion: ((Outcome) -> Void)?

    init(request: CEFWebAuthnRequest, window: NSWindow) {
        self.request = request
        self.window = window
    }

    /// Starts the system sheet; `completion` runs once, unless ``cancel()`` comes first.
    func start(platform: Bool, completion: @escaping (Outcome) -> Void) {
        let requests = Self.authorizationRequests(for: request, platform: platform)
        guard !requests.isEmpty else {
            return completion(.failure(name: "NotSupportedError", message: "No authenticator in this browser can answer this request."))
        }
        self.completion = completion
        let controller = ASAuthorizationController(authorizationRequests: requests)
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        controller.performRequests()
    }

    /// Chromium ended the request (abort, timeout, the document is gone): the sheet closes, no answer.
    func cancel() {
        completion = nil
        controller?.cancel()
        controller = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(Self.outcome(authorization.credential, request: request))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let code = (error as NSError).domain == ASAuthorizationError.errorDomain ? (error as NSError).code : 0
        // ASAuthorizationError.matchedExcludedCredential (1006, macOS 15): the authenticator already holds one.
        if code == 1006 {
            finish(.failure(name: "InvalidStateError", message: "The authenticator already has a credential for this account."))
        } else {
            finish(.failure(name: "NotAllowedError", message: "The request was cancelled or refused."))
        }
    }

    private func finish(_ outcome: Outcome) {
        controller = nil
        guard let completion else { return }
        self.completion = nil
        completion(outcome)
    }

    // MARK: Requests

    static func authorizationRequests(for request: CEFWebAuthnRequest, platform: Bool) -> [ASAuthorizationRequest] {
        let options = request.options
        guard let challenge = options.challenge else { return [] }
        let clientData = ASPublicKeyCredentialClientData(
            challenge: challenge, origin: request.origin, topOrigin: request.crossOrigin ? request.topOrigin : nil,
            crossOrigin: request.crossOrigin ? .crossOrigin : .sameOriginWithAncestors)
        let verification = ASAuthorizationPublicKeyCredentialUserVerificationPreference(rawValue: options.userVerification)
        var requests = platformRequest(request, clientData, verification, platform && options.attachment != "cross-platform")
        // The browser form of a security key request is macOS 14.4 and later.
        guard #available(macOS 14.4, *), options.attachment != "platform" else { return requests }
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: request.rpID)
        let descriptors = options.credentials.map { ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: $0.id, transports: transports($0.transports)) }
        switch request.kind {
        case .create:
            guard let userID = options.userID else { return requests }
            let item = provider.createCredentialRegistrationRequest(clientData: clientData, displayName: options.userDisplayName,
                                                                    name: options.userName, userID: userID)
            let algorithms = options.algorithms.isEmpty ? [ASCOSEAlgorithmIdentifier.ES256.rawValue] : options.algorithms
            item.credentialParameters = algorithms.map { ASAuthorizationPublicKeyCredentialParameters(algorithm: ASCOSEAlgorithmIdentifier(rawValue: $0)) }
            item.excludedCredentials = descriptors
            item.residentKeyPreference = ASAuthorizationPublicKeyCredentialResidentKeyPreference(rawValue: options.residentKey)
            item.userVerificationPreference = verification
            item.attestationPreference = ASAuthorizationPublicKeyCredentialAttestationKind(rawValue: options.attestation)
            requests.append(item)
        case .get:
            let item = provider.createCredentialAssertionRequest(clientData: clientData)
            item.allowedCredentials = descriptors
            item.userVerificationPreference = verification
            if #available(macOS 14.5, *), let appID = options.appID { item.appID = appID }
            requests.append(item)
        }
        return requests
    }

    /// The platform request: passkey providers and a phone. Only ES256 keys come from it.
    private static func platformRequest(_ request: CEFWebAuthnRequest, _ clientData: ASPublicKeyCredentialClientData,
                                        _ verification: ASAuthorizationPublicKeyCredentialUserVerificationPreference,
                                        _ enabled: Bool) -> [ASAuthorizationRequest] {
        let options = request.options
        guard enabled else { return [] }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: request.rpID)
        let descriptors = options.credentials.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0.id) }
        switch request.kind {
        case .create:
            guard let userID = options.userID,
                  options.algorithms.isEmpty || options.algorithms.contains(ASCOSEAlgorithmIdentifier.ES256.rawValue) else { return [] }
            let item = provider.createCredentialRegistrationRequest(clientData: clientData, name: options.userName, userID: userID)
            if !options.userDisplayName.isEmpty { item.displayName = options.userDisplayName }
            item.userVerificationPreference = verification
            item.attestationPreference = ASAuthorizationPublicKeyCredentialAttestationKind(rawValue: options.attestation)
            item.excludedCredentials = descriptors
            item.shouldShowHybridTransport = true
            return [item]
        case .get:
            let item = provider.createCredentialAssertionRequest(clientData: clientData)
            item.allowedCredentials = descriptors
            item.userVerificationPreference = verification
            item.shouldShowHybridTransport = true
            return [item]
        }
    }

    @available(macOS 14.4, *)
    private static func transports(_ names: [String]) -> [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport] {
        let mapped = names.compactMap { name -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport? in
            switch name {
            case "usb": .usb
            case "nfc": .nfc
            case "ble": .bluetooth
            default: nil
            }
        }
        return mapped.isEmpty ? ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported : mapped
    }

    // MARK: Results

    static func outcome(_ credential: any ASAuthorizationCredential, request: CEFWebAuthnRequest) -> Outcome {
        let refused = Outcome.failure(name: "NotAllowedError", message: "The authenticator gave no usable credential.")
        do throws(CEFWebAuthnCredentialJSON.Failure) {
            switch credential {
            case let created as ASAuthorizationPlatformPublicKeyCredentialRegistration:
                guard let attestation = created.rawAttestationObject else { return refused }
                let phone = created.attachment == .crossPlatform
                return .credential(json: try CEFWebAuthnCredentialJSON.registration(
                    credentialID: created.credentialID, clientDataJSON: created.rawClientDataJSON, attestationObject: attestation,
                    attachment: phone ? "cross-platform" : "platform", transports: phone ? ["hybrid"] : ["hybrid", "internal"],
                    // A platform passkey is always discoverable.
                    extensions: request.options.credProps ? ["credProps": ["rk": true]] : [:]))
            case let created as ASAuthorizationSecurityKeyPublicKeyCredentialRegistration:
                guard let attestation = created.rawAttestationObject else { return refused }
                return .credential(json: try CEFWebAuthnCredentialJSON.registration(
                    credentialID: created.credentialID, clientDataJSON: created.rawClientDataJSON, attestationObject: attestation,
                    attachment: "cross-platform", transports: securityKeyTransports(created), extensions: [:]))
            case let assertion as ASAuthorizationPlatformPublicKeyCredentialAssertion:
                return .credential(json: CEFWebAuthnCredentialJSON.assertion(
                    credentialID: assertion.credentialID, clientDataJSON: assertion.rawClientDataJSON,
                    authenticatorData: assertion.rawAuthenticatorData, signature: assertion.signature, userHandle: assertion.userID,
                    attachment: assertion.attachment == .crossPlatform ? "cross-platform" : "platform", extensions: [:]))
            case let assertion as ASAuthorizationSecurityKeyPublicKeyCredentialAssertion:
                var extensions: [String: Any] = [:]
                if #available(macOS 14.5, *), request.options.appID != nil { extensions["appid"] = assertion.appID }
                return .credential(json: CEFWebAuthnCredentialJSON.assertion(
                    credentialID: assertion.credentialID, clientDataJSON: assertion.rawClientDataJSON,
                    authenticatorData: assertion.rawAuthenticatorData, signature: assertion.signature, userHandle: assertion.userID,
                    attachment: "cross-platform", extensions: extensions))
            default:
                return refused
            }
        } catch {
            return refused
        }
    }

    private static func securityKeyTransports(_ created: ASAuthorizationSecurityKeyPublicKeyCredentialRegistration) -> [String] {
        guard #available(macOS 14.5, *) else { return ["usb"] }
        let names = created.transports.compactMap { transport -> String? in
            switch transport {
            case .usb: "usb"
            case .nfc: "nfc"
            case .bluetooth: "ble"
            default: nil
            }
        }
        return names.isEmpty ? ["usb"] : names
    }
}
