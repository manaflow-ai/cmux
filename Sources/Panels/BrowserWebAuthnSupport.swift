import AppKit
import AuthenticationServices
import Bonsplit
import CoreBluetooth
import Foundation
import ObjectiveC.runtime
import WebKit

final class BrowserWebAuthnCoordinator: NSObject, WKScriptMessageHandlerWithReply {
    var activeAuthorizationController: ASAuthorizationController?
    var activeAuthorizationContinuation: CheckedContinuation<[String: Any], Error>?
    var activePresentationWindow: NSWindow?

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
                    let request = try BrowserWebAuthnRequestParser.decodePayload(
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
                    let request = try BrowserWebAuthnRequestParser.decodePayload(
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

