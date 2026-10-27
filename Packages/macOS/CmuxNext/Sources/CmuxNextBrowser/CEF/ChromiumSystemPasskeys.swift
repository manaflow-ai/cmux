import AppKit
import AuthenticationServices
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Security

/// iCloud Keychain in cmux.app for the Chromium Host's pages, as Chrome's browser process runs it
/// (device/fido/mac/icloud_keychain_sys.mm, `NativeSystemInterface`), with one difference: Chrome sets the
/// client data hash through a private override (`_requestContextWithRequests:`), and cmux uses no private
/// selector (K9), so the system builds the client data from ``ChromiumPasskeyCeremony``'s members with
/// the public browser API (`ASPublicKeyCredentialClientData`, macOS 13.5) and ``ChromiumPasskeyReply``
/// checks that it built Chromium's bytes.
final class ChromiumSystemPasskeys: ChromiumPlatformPasskeySystem {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    let isAvailable: Bool
    private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()

    init() {
        isAvailable = Self.hasEntitlement()
    }

    var permission: ChromiumPasskeyPermission {
        Self.permission(manager.authorizationStateForPlatformCredentials)
    }

    func requestPermission() async -> ChromiumPasskeyPermission {
        let manager = manager
        // A completion dropped uncalled decided nothing.
        let state = try? await withOnceContinuation { (continuation: OnceContinuation<ChromiumPasskeyPermission, OnceContinuationError>) in
            manager.requestAuthorizationForPublicKeyCredentials { state in
                continuation.resume(returning: Self.permission(state))
            }
        }
        return state ?? permission
    }

    /// A manager of its own, off the main actor, as Chrome asks a new one each time (icloud_keychain_sys.mm `GetManager`).
    @concurrent
    nonisolated func credentials(forRelyingParty rpID: String) async -> [ChromiumPlatformCredential] {
        await ASAuthorizationWebBrowserPublicKeyCredentialManager().platformCredentials(forRelyingParty: rpID).map {
            ChromiumPlatformCredential(credentialID: $0.credentialID, userHandle: $0.userHandle, name: $0.name,
                                       providerName: $0.providerName)
        }
    }

    func start(_ ceremony: ChromiumPasskeyCeremony, anchor: NSWindow) -> any ChromiumPasskeyRun {
        ChromiumPasskeySheet(request: Self.request(for: ceremony), anchor: anchor)
    }

    /// The request Chrome makes (icloud_keychain_sys.mm MakeCredential and GetAssertion): ES256 only,
    /// no attestation, the person's user verification, hybrid off on a get.
    static func request(for ceremony: ChromiumPasskeyCeremony) -> ASAuthorizationRequest {
        let crossOrigin = ceremony.crossOrigin.map { $0 ? ASPublicKeyCredentialClientData.CrossOriginValue.crossOrigin : .sameOriginWithAncestors }
        let clientData = ASPublicKeyCredentialClientData(challenge: ceremony.challenge, origin: ceremony.origin,
                                                         topOrigin: ceremony.topOrigin, crossOrigin: crossOrigin)
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: ceremony.rpID)
        let preference = ASAuthorizationPublicKeyCredentialUserVerificationPreference(rawValue: ceremony.userVerification)
        switch ceremony.kind {
        case .create(let user, let excluded):
            let request = provider.createCredentialRegistrationRequest(clientData: clientData, name: user.name, userID: user.id)
            request.displayName = user.displayName
            request.attestationPreference = ASAuthorizationPublicKeyCredentialAttestationKind.none
            request.userVerificationPreference = preference
            if !excluded.isEmpty {
                request.excludedCredentials = excluded.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
            }
            request.shouldShowHybridTransport = false
            return request
        case .get(let allowed, let showsHybridTransport):
            let request = provider.createCredentialAssertionRequest(clientData: clientData)
            request.allowedCredentials = allowed.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
            request.userVerificationPreference = preference
            request.shouldShowHybridTransport = showsHybridTransport
            return request
        }
    }

    nonisolated static func permission(_ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState) -> ChromiumPasskeyPermission {
        switch state {
        case .authorized: .authorized
        case .denied: .denied
        default: .notDetermined
        }
    }

    /// Chromium's `ProcessHasEntitlement` (icloud_keychain_sys.mm), public Security calls only.
    private static func hasEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        // SAFETY: no error out-parameter is passed (nil); the value is a CF object Swift releases.
        return unsafe SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) != nil
    }
}

/// One `ASAuthorizationController` ceremony over the pane's window, Chrome's `ICloudKeychainDelegate` and
/// `ICloudKeychainPresentationDelegate`: the anchor is that window, never a new one (K10).
final class ChromiumPasskeySheet: NSObject, ChromiumPasskeyRun {
    private let controller: ASAuthorizationController
    private let anchor: NSWindow
    private var outcome: ChromiumPasskeyCeremonyResult?
    private var waiter: OnceContinuation<ChromiumPasskeyCeremonyResult, OnceContinuationError>?

    init(request: ASAuthorizationRequest, anchor: NSWindow) {
        controller = ASAuthorizationController(authorizationRequests: [request])
        self.anchor = anchor
        super.init()
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func result() async -> ChromiumPasskeyCeremonyResult {
        if let outcome { return outcome }
        let ended = try? await withOnceContinuation { (continuation: OnceContinuation<ChromiumPasskeyCeremonyResult, OnceContinuationError>) in
            waiter = continuation
        }
        return ended ?? outcome ?? Self.dropped
    }

    func cancel() {
        controller.cancel()
    }

    /// A ceremony whose controller ended without a callback.
    private static let dropped = ChromiumPasskeyCeremonyResult.failure(domain: ASAuthorizationErrorDomain,
                                                                       code: ASAuthorizationError.Code.unknown.rawValue,
                                                                       description: "The passkey request ended.")

    private func finish(_ result: ChromiumPasskeyCeremonyResult) {
        guard outcome == nil else { return }
        outcome = result
        waiter?.resume(returning: result)
        waiter = nil
    }

    private static func result(of credential: any ASAuthorizationCredential) -> ChromiumPasskeyCeremonyResult {
        if let registration = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
            return .registration(credentialID: registration.credentialID, attestationObject: registration.rawAttestationObject,
                                 clientDataJSON: registration.rawClientDataJSON)
        }
        if let assertion = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            // These are implicitly unwrapped; `userID` is nil for a credential without a user handle (K11). Each is read
            // as an optional, never unwrapped.
            let (authenticatorData, signature, userHandle): (Data?, Data?, Data?) = (assertion.rawAuthenticatorData, assertion.signature,
                                                                                    assertion.userID)
            guard let authenticatorData, let signature else { return dropped }
            return .assertion(credentialID: assertion.credentialID, authenticatorData: authenticatorData,
                              signature: signature, userHandle: userHandle, clientDataJSON: assertion.rawClientDataJSON)
        }
        return dropped
    }
}

extension ChromiumPasskeySheet: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(Self.result(of: authorization.credential))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let error = error as NSError
        finish(.failure(domain: error.domain, code: error.code, description: error.localizedDescription))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor
    }
}
