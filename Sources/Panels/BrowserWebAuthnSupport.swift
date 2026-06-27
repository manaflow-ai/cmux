import AppKit
import AuthenticationServices
import Bonsplit
import CmuxBrowser
import Foundation
import ObjectiveC.runtime
import WebKit

final class BrowserWebAuthnCoordinator: NSObject, WKScriptMessageHandlerWithReply {
    private var activeAuthorizationController: ASAuthorizationController?
    private var activeAuthorizationContinuation: CheckedContinuation<[String: Any], Error>?
    private var activePresentationWindow: NSWindow?
    private let requestParser = BrowserWebAuthnRequestParser()
    private let replyMarshaler = BrowserWebAuthnCredentialReplyMarshaler()

    override init() {
        super.init()
    }

    #if DEBUG
    private func debugHasValue(_ value: String?) -> Int {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? 1 : 0
    }
    #endif

    func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: BrowserWebAuthnBridgeContract.standard.handlerName, contentWorld: .page)
        controller.addScriptMessageHandler(self, contentWorld: .page, name: BrowserWebAuthnBridgeContract.standard.handlerName)
    }

    func uninstall(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserWebAuthnBridgeContract.standard.handlerName,
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
                let envelope = try requestParser.parseEnvelope(from: message.body)
                #if DEBUG
                cmuxDebugLog("webauthn.dispatch kind=\(envelope.kind.rawValue) frame=\(message.frameInfo.isMainFrame ? "main" : "sub") url=\(message.frameInfo.securityOrigin.host)")
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
                    cmuxDebugLog("webauthn.capabilities reply=\(capReply)")
                    #endif
                    replyHandler(capReply, nil)
                case .createCredential:
                    let request = try requestParser.decodePayload(
                        BrowserWebAuthnCreationRequest.self,
                        from: envelope
                    )
                    #if DEBUG
                    cmuxDebugLog(
                        "webauthn.createCredential hasRP=\(debugHasValue(request.publicKey.rp?.id)) " +
                        "hasUserName=\(debugHasValue(request.publicKey.user.name)) " +
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
                    let request = try requestParser.decodePayload(
                        BrowserWebAuthnAssertionRequest.self,
                        from: envelope
                    )
                    #if DEBUG
                    cmuxDebugLog(
                        "webauthn.getCredential hasRPID=\(debugHasValue(request.publicKey.rpId)) " +
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
                    try replyMarshaler.successCredentialReply(from: authorization.credential)
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
        let clientDataContext = try BrowserWebAuthnClientDataContext.resolve(for: message)
        guard let plan = try request.nativeRequestPlan(clientDataContext: clientDataContext) else {
            #if DEBUG
            cmuxDebugLog("webauthn.handleCreate no plan — returning fallback")
            #endif
            return fallbackReply()
        }

        let requests = try await authorizationRequests(for: plan, message: message)
        guard !requests.isEmpty else {
            #if DEBUG
            cmuxDebugLog("webauthn.handleCreate authorizationRequests empty — returning fallback")
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
        cmuxDebugLog(
            "webauthn.handleGet BEGIN origin=\(message.frameInfo.securityOrigin.host) " +
            "webViewHost=\(message.webView?.url?.host ?? "(nil)") hasWebViewURL=\(message.webView?.url == nil ? 0 : 1)"
        )
        #endif
        let clientDataContext = try BrowserWebAuthnClientDataContext.resolve(for: message)
        guard let plan = try request.nativeRequestPlan(clientDataContext: clientDataContext) else {
            #if DEBUG
            cmuxDebugLog("webauthn.handleGet no plan — returning fallback")
            #endif
            return fallbackReply()
        }

        let requests = try await authorizationRequests(for: plan, message: message)
        guard !requests.isEmpty else {
            #if DEBUG
            cmuxDebugLog("webauthn.handleGet authorizationRequests empty — returning fallback")
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
        guard let window else {
            #if DEBUG
            cmuxDebugLog("webauthn.performAuth FAIL: no window")
            #endif
            throw BrowserWebAuthnBridgeError.notSupported("Native passkey support is unavailable.")
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
        let platformPasskeyAvailability = state.browserAdvertisedPlatformPasskeyAvailability(
            deviceConfiguredForPasskeys: deviceConfiguredForPasskeys,
            callerMayPromptForPlatformAuthorization: callerMayPromptForPlatformAuthorization
        )
        #if DEBUG
        cmuxDebugLog("webauthn.capability state=\(state.rawValue) authorized=\(authorized) denied=\(denied) canPrompt=\(canPromptForAccess) callerMayPrompt=\(callerMayPromptForPlatformAuthorization) platformSupport=\(platformRequestSupport) securityKeySupport=\(securityKeySupport) deviceConfigured=\(deviceConfiguredForPasskeys as Any) advertisedPlatform=\(platformPasskeyAvailability as Any) btAuth=\(bluetoothState.isAuthorized) btHybrid=\(bluetoothState.canUseHybridTransport)")
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
