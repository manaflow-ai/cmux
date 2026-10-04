import Foundation
import WebKit

/// The page's first WebAuthn call while browser passkey authorization is
/// undecided (`WebKitPasskeyScript`). The app asks the person only for a
/// main frame or a frame of the main frame's origin, and only right after
/// the person's own input, so a page cannot raise the system prompt by
/// itself; the page's call then goes on either way and WebKit decides.
extension WebKitTab {
    var passkeyAuthorization: WebKitPasskeyAuthorization { engine?.passkeyAuthorization ?? .shared }

    func installPasskeyAuthorization(into controller: WKUserContentController) {
        guard passkeyAuthorization.state == .notDetermined else { return }
        controller.addUserScript(WKUserScript(source: WebKitPasskeyScript.source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
        controller.addScriptMessageHandler(WeakPasskeyReplyHandler(self), contentWorld: .page, name: WebKitPasskeyScript.messageHandlerName)
    }

    func passkeyAuthorizationMessage(frameOrigin: WKSecurityOrigin, isMainFrame: Bool) async -> String {
        let mainOrigin = webView.url.map { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let sameOrigin = isMainFrame || (mainOrigin??.host == frameOrigin.host && mainOrigin??.scheme == frameOrigin.protocol)
        let recentInput = (webView as? WebKitWebView)?.hadRecentUserInput() ?? false
        guard WebKitPasskeyIntent.mayAsk(sameOriginAsMainFrame: sameOrigin, recentUserInput: recentInput, agentDriven: isAgentDriven) else {
            return passkeyAuthorization.state.rawValue
        }
        return await passkeyAuthorization.requestIfNeeded().rawValue
    }
}

/// When a page's WebAuthn call may raise the authorization prompt.
nonisolated enum WebKitPasskeyIntent {
    static func mayAsk(sameOriginAsMainFrame: Bool, recentUserInput: Bool, agentDriven: Bool) -> Bool {
        sameOriginAsMainFrame && recentUserInput && !agentDriven
    }
}

/// Breaks the retain cycle between the content controller and the tab.
final class WeakPasskeyReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var tab: WebKitTab?

    init(_ tab: WebKitTab) { self.tab = tab }

    @MainActor
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let tab else { return (WebKitPasskeyAuthorization.State.notDetermined.rawValue, nil) }
        let answer = await tab.passkeyAuthorizationMessage(frameOrigin: message.frameInfo.securityOrigin, isMainFrame: message.frameInfo.isMainFrame)
        return (answer, nil)
    }
}
