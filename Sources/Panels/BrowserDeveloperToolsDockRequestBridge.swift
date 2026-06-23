import ObjectiveC.runtime
import WebKit

@MainActor
enum BrowserDeveloperToolsDockRequestBridge {
    static let messageHandlerName = "cmuxDevToolsDock"

    private static var handlerKey: UInt8 = 0

    static func install(on inspectorFrontendWebView: WKWebView, panel: BrowserPanel) {
        let userContentController = inspectorFrontendWebView.configuration.userContentController
        if let handler = objc_getAssociatedObject(
            userContentController,
            &handlerKey
        ) as? BrowserDeveloperToolsDockRequestMessageHandler {
            handler.panel = panel
            return
        }

        let handler = BrowserDeveloperToolsDockRequestMessageHandler(panel: panel)
        userContentController.add(handler, name: messageHandlerName)
        objc_setAssociatedObject(
            userContentController,
            &handlerKey,
            handler,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

extension BrowserPanel {
    @discardableResult
    func handleDeveloperToolsDockRequestFromFrontend(side: String) -> Bool {
        let normalizedSide = side.lowercased()
        guard ["left", "right", "bottom"].contains(normalizedSide),
              webView.cmuxInspectorObject() != nil else {
            return false
        }

#if DEBUG
        cmuxDebugLog(
            "browser.devtools dockRequest panel=\(id.uuidString.prefix(5)) side=\(normalizedSide) result=unsupported"
        )
#endif
        return false
    }
}

private final class BrowserDeveloperToolsDockRequestMessageHandler: NSObject, WKScriptMessageHandler {
    weak var panel: BrowserPanel?

    init(panel: BrowserPanel) {
        self.panel = panel
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == BrowserDeveloperToolsDockRequestBridge.messageHandlerName else { return }
        let side: String?
        if let body = message.body as? [String: Any] {
            side = body["side"] as? String
        } else {
            side = message.body as? String
        }
        guard let side else { return }
        MainActor.assumeIsolated {
            _ = panel?.handleDeveloperToolsDockRequestFromFrontend(side: side)
        }
    }
}
