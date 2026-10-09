import Foundation
import WebKit

/// The page's first WebAuthn call while browser passkey authorization is
/// undecided (`WebKitPasskeyScript`). The app asks the person only for a
/// main frame or a frame of the main frame's origin, and only right after
/// the person's own input, so a page cannot raise the system prompt by
/// itself; the page's call then goes on either way and WebKit decides.
@MainActor
enum WebKitPasskeyInstaller {
    static func authorization(for tab: WebKitTab) -> WebKitPasskeyAuthorization { tab.engine?.passkeyAuthorization ?? .shared }

    static func install(_ tab: WebKitTab, into controller: WKUserContentController) {
        guard authorization(for: tab).state == .notDetermined else { return }
        controller.addUserScript(WKUserScript(source: WebKitPasskeyScript.source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
        controller.addScriptMessageHandler(WeakPasskeyReplyHandler(tab), contentWorld: .page, name: WebKitPasskeyScript.messageHandlerName)
    }

    static func answer(_ tab: WebKitTab, frameOrigin: WKSecurityOrigin, isMainFrame: Bool) async -> String {
        let mainOrigin = tab.webView.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let sameOrigin = isMainFrame || (mainOrigin?.host == frameOrigin.host && mainOrigin?.scheme == frameOrigin.protocol)
        let recentInput = (tab.webView as? WebKitWebView)?.hadRecentUserInput() ?? false
        guard WebKitPasskeyIntent.mayAsk(sameOriginAsMainFrame: sameOrigin, recentUserInput: recentInput, agentDriven: tab.isAgentDriven) else {
            return authorization(for: tab).state.rawValue
        }
        return await authorization(for: tab).requestIfNeeded().rawValue
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

    // Completion-handler form: Xcode 26.6's compiler crashes emitting the ObjC
    // thunk for async delegate methods.
    @MainActor
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let tab else {
            replyHandler(WebKitPasskeyAuthorization.State.notDetermined.rawValue, nil)
            return
        }
        let frameOrigin = message.frameInfo.securityOrigin
        let isMainFrame = message.frameInfo.isMainFrame
        Task { @MainActor in
            let answer = await WebKitPasskeyInstaller.answer(tab, frameOrigin: frameOrigin, isMainFrame: isMainFrame)
            replyHandler(answer, nil)
        }
    }
}
