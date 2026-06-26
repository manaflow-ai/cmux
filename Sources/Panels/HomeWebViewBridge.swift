import AppKit
import Foundation
import ObjectiveC
import WebKit

@MainActor
final class HomeWebViewBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "cmuxHome"
    static let shared = HomeWebViewBridge()

    private static var handlerInstalledKey: UInt8 = 0
    private static var panelAssociationKey: UInt8 = 0

    private final class PanelAssociation: NSObject {
        let panelId: UUID
        let workspaceId: UUID

        init(panelId: UUID, workspaceId: UUID) {
            self.panelId = panelId
            self.workspaceId = workspaceId
        }
    }

    private enum BridgeError: Error {
        case notAllowed
        case invalidRequest
        case actionFailed

        var code: String {
            switch self {
            case .notAllowed: return "not_allowed"
            case .invalidRequest: return "invalid_request"
            case .actionFailed: return "action_failed"
            }
        }
    }

    static func installIfNeeded(on userContentController: WKUserContentController) {
        guard objc_getAssociatedObject(userContentController, &handlerInstalledKey) == nil else {
            return
        }
        userContentController.addScriptMessageHandler(
            shared,
            contentWorld: .page,
            name: handlerName
        )
        objc_setAssociatedObject(
            userContentController,
            &handlerInstalledKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func associate(panelId: UUID, workspaceId: UUID, with webView: WKWebView) {
        objc_setAssociatedObject(
            webView,
            &panelAssociationKey,
            PanelAssociation(panelId: panelId, workspaceId: workspaceId),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard Self.isTrustedHomeFrame(message.frameInfo) else {
            replyHandler(Self.errorReply(.notAllowed), nil)
            return
        }
        do {
            let value = try handle(body: message.body, webView: message.webView)
            replyHandler(["ok": true, "value": value], nil)
        } catch let error as BridgeError {
            replyHandler(Self.errorReply(error), nil)
        } catch {
            replyHandler(Self.errorReply(.actionFailed), nil)
        }
    }

    private static func errorReply(_ error: BridgeError) -> [String: Any] {
        ["ok": false, "error": ["code": error.code]]
    }

    static func isTrustedHomeFrame(_ frameInfo: WKFrameInfo) -> Bool {
        guard frameInfo.isMainFrame,
              let url = frameInfo.request.url else {
            return false
        }
        return url.scheme == CmuxBundledWebViewURLSchemeHandler.scheme &&
            url.host == "home" &&
            url.path == "/home.html"
    }

    private func handle(body: Any, webView: WKWebView?) throws -> Any {
        guard let body = body as? [String: Any],
              let action = body["action"] as? String else {
            throw BridgeError.invalidRequest
        }
        guard let appDelegate = AppDelegate.shared else {
            throw BridgeError.actionFailed
        }
        let context = webView.flatMap(Self.mainWindowContext(for:))
        let tabManager = context?.tabManager
        let window = context.flatMap { appDelegate.resolvedWindow(for: $0) }

        switch action {
        case "newWorkspace":
            guard appDelegate.performNewWorkspaceAction(
                tabManager: tabManager,
                debugSource: "home.webview.newWorkspace"
            ) else {
                throw BridgeError.actionFailed
            }
        case "newBrowser":
            guard appDelegate.performNewBrowserWorkspaceAction(
                tabManager: tabManager,
                debugSource: "home.webview.newBrowser"
            ) else {
                throw BridgeError.actionFailed
            }
        case "commandPalette":
            appDelegate.requestCommandPaletteCommands(
                preferredWindow: window,
                source: "home.webview.commandPalette"
            )
        case "settings":
            appDelegate.openPreferencesWindow(debugSource: "home.webview.settings")
        default:
            throw BridgeError.invalidRequest
        }

        return ["action": action]
    }

    private static func mainWindowContext(for webView: WKWebView) -> AppDelegate.MainWindowContext? {
        guard let association = objc_getAssociatedObject(
            webView,
            &panelAssociationKey
        ) as? PanelAssociation else {
            return nil
        }
        return AppDelegate.shared?.mainWindowContexts.values.first { context in
            context.tabManager.tabs.contains { workspace in
                workspace.id == association.workspaceId &&
                    workspace.panels.keys.contains(association.panelId)
            }
        }
    }
}
