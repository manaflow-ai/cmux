import AppKit
import AuthenticationServices
import Bonsplit
import CmuxBrowser
import CoreBluetooth
import Foundation
import ObjectiveC.runtime
import WebKit

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
    private let requestParser = BrowserWebAuthnRequestParser()

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
        let clientDataContext = try BrowserWebAuthnClientDataContext.resolve(for: message)
        guard let plan = try buildCreationPlan(request, clientDataContext: clientDataContext) else {
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
        guard let plan = try buildAssertionPlan(request, clientDataContext: clientDataContext) else {
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
