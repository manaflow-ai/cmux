import Foundation
import WebKit

/// The engine-neutral host bridge (``PaneHostBridge``), behind a DEBUG-only
/// switch: `CMUX_NEXT_PANE_HOST_BRIDGE=1` answers the page through
/// ``WebKitPaneHostBridge`` and ``makePaneHostHandler()``, the path a CEF
/// pane uses with ``CEFPaneHostBridge``. Without it (and in every Release
/// build) the pane keeps ``AgentPaneBridge``.
extension AgentPaneView {
    static let paneHostBridgeVariable = "CMUX_NEXT_PANE_HOST_BRIDGE"

    static var usesPaneHostBridge: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment[paneHostBridgeVariable] == "1"
        #else
        false
        #endif
    }

    func installHostBridge(on configuration: WKWebViewConfiguration) {
        if Self.usesPaneHostBridge {
            WebKitPaneHostBridge(webView: webView).attach(makePaneHostHandler())
        } else {
            configuration.userContentController.addScriptMessageHandler(
                AgentPaneBridge(view: self), contentWorld: .page, name: AgentPaneRequest.handlerName)
        }
    }

    /// This pane's answers to page requests on any engine, with
    /// ``AgentPaneBridge``'s rules: only the pane's own top-level page is
    /// trusted, `ready` re-pushes theme, shortcuts, preview features and
    /// customization, and only the model is held across the reply (the
    /// handshake can wait 20 seconds), so closing the tab frees the view.
    func makePaneHostHandler() -> PaneHostHandler {
        { [weak self] message in
            switch self?.preparePaneHost(message) {
            case nil:
                return AgentPaneReply.failure(code: "closed", message: "Closed")
            case .untrusted?:
                return AgentPaneReply.failure(code: "untrusted_frame", message: "Untrusted frame")
            case .answer(let model, let request)?:
                return await model.respond(to: request)
            }
        }
    }

    enum PaneHostPrepared {
        case untrusted
        case answer(AgentPaneModel, AgentPaneRequest)
    }

    func preparePaneHost(_ message: PaneHostMessage) -> PaneHostPrepared {
        guard PaneHostTrust.isTrusted(message, source: source) else { return .untrusted }
        let request = AgentPaneRequest(body: message.body)
        if request == .ready {
            applyTheme()
            applyShortcuts()
            applyPreviewFeatures()
            replayCustomization()
        }
        return .answer(model, request)
    }
}
