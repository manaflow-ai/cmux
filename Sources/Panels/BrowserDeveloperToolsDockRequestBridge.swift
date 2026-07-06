import ObjectiveC.runtime
import WebKit

@MainActor
extension BrowserPanel {
    func installDeveloperToolsDockRequestBridge(on inspectorFrontendWebView: WKWebView) {
        let userContentController = inspectorFrontendWebView.configuration.userContentController
        BrowserDeveloperToolsDockRequestMessageHandler.install(on: userContentController, panel: self)
    }

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
    private static let messageHandlerName = "cmuxDevToolsDock"
    private static var associationKey: UInt8 = 0

    weak var panel: BrowserPanel?

    init(panel: BrowserPanel) {
        self.panel = panel
    }

    static func install(on userContentController: WKUserContentController, panel: BrowserPanel) {
        if let handler = objc_getAssociatedObject(
            userContentController,
            &associationKey
        ) as? BrowserDeveloperToolsDockRequestMessageHandler {
            handler.panel = panel
            return
        }

        let handler = BrowserDeveloperToolsDockRequestMessageHandler(panel: panel)
        userContentController.add(handler, name: messageHandlerName)
        objc_setAssociatedObject(
            userContentController,
            &associationKey,
            handler,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageHandlerName else { return }
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
