import AppKit
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
              let inspector = webView.cmuxInspectorObject() else {
            return false
        }

        _ = showDeveloperTools()
        if hostDetachedDeveloperToolsFrontend(side: normalizedSide) {
#if DEBUG
            cmuxDebugLog(
                "browser.devtools dockRequest panel=\(id.uuidString.prefix(5)) side=\(normalizedSide) result=hosted"
            )
#endif
            return true
        }

        let isAttachedSelector = NSSelectorFromString("isAttached")
        guard !(inspector.cmuxDockRequestCallBool(selector: isAttachedSelector) ?? false) else {
            return true
        }

        let attachSelector = NSSelectorFromString("attach")
        guard inspector.responds(to: attachSelector) else { return false }
#if DEBUG
        cmuxDebugLog(
            "browser.devtools dockRequest panel=\(id.uuidString.prefix(5)) side=\(normalizedSide) attach=1"
        )
#endif
        inspector.cmuxDockRequestCallVoid(selector: attachSelector)
        return true
    }

    private func hostDetachedDeveloperToolsFrontend(side: String) -> Bool {
        guard let frontendWebView = webView.cmuxInspectorFrontendWebView(),
              let hostView = webView.superview,
              let detachedWindow = frontendWebView.window,
              detachedWindow !== webView.window else {
            return false
        }

        let bounds = hostView.bounds
        guard bounds.width > 1, bounds.height > 1 else { return false }

        let inspectorFrame: NSRect
        let pageFrame: NSRect
        switch side {
        case "left":
            let width = min(max(320, bounds.width * 0.35), max(120, bounds.width - 240))
            inspectorFrame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            pageFrame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        case "right":
            let width = min(max(320, bounds.width * 0.35), max(120, bounds.width - 240))
            pageFrame = NSRect(x: 0, y: 0, width: max(0, bounds.width - width), height: bounds.height)
            inspectorFrame = NSRect(x: pageFrame.maxX, y: 0, width: width, height: bounds.height)
        default:
            let height = min(max(260, bounds.height * 0.42), max(120, bounds.height - 240))
            inspectorFrame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
            pageFrame = NSRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
        }

        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = []
        webView.frame = pageFrame
        frontendWebView.removeFromSuperview()
        frontendWebView.translatesAutoresizingMaskIntoConstraints = true
        frontendWebView.autoresizingMask = []
        frontendWebView.frame = inspectorFrame
        hostView.addSubview(frontendWebView, positioned: .above, relativeTo: webView)
        detachedWindow.close()
        adoptAttachedDeveloperToolsRedock(source: "dockRequest.\(side)")
        normalizeDeveloperToolsDockControls()
        hostView.needsLayout = true
        hostView.needsDisplay = true
        hostView.layoutSubtreeIfNeeded()
        hostView.displayIfNeeded()
        return true
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

private extension NSObject {
    func cmuxDockRequestCallBool(selector: Selector) -> Bool? {
        guard responds(to: selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        return fn(self, selector)
    }

    func cmuxDockRequestCallVoid(selector: Selector) {
        guard responds(to: selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
    }
}
