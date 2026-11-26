import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import Foundation

/// A menu of the page with no room above or below its anchor in the pane shows past the window's
/// edge (cx-6k6cg, ``WebPopupHost``): `popup.show`, `popup.update` and `popup.hide` from the page;
/// the host's `pick`, `highlight` and `dismiss` go back as the window event `cmux-popup`.
extension AgentPaneView {
    func popup(_ method: String, params: [String: Any]) -> [String: Any] {
        switch method {
        case "popup.show", "popup.update":
            guard let model = WebPopupHost.Model(params) else { return AgentPaneReply.failure(code: "invalid_params", message: "Bad popup") }
            let host = popupHostStorage ?? WebPopupHost(
                webView: webView, zoom: { [weak self] in self?.webView.pageZoom ?? 1 },
                send: { [weak self] event in self?.sendPopupEvent(event) })
            popupHostStorage = host
            if method == "popup.update" {
                host.update(model)
                return ["ok": true, "value": [:] as [String: Any]]
            }
            return ["ok": true, "value": host.show(model)]
        case "popup.hide":
            popupHostStorage?.hideRequest(params)
            return ["ok": true, "value": [:] as [String: Any]]
        default:
            return AgentPaneReply.failure(code: "unknown_method", message: "Unknown popup method")
        }
    }

    /// The page's right-click menu (`ui/ContextMenu.tsx`) as a standard macOS menu at the pointer
    /// (``WebContextMenu``): `reply` gets `{picked}` once it closes, null when dismissed.
    static let contextMenuMethod = "contextMenu.show"

    func contextMenu(params: [String: Any], reply: @escaping @MainActor ([String: Any]) -> Void) {
        guard let menu = WebContextMenu(params) else { return reply(["ok": true, "value": ["picked": NSNull()]]) }
        menu.present(in: webView, zoom: webView.pageZoom) { [weak self] picked in
            // A legacy bridge has no PageCallContext. The menu choice itself is the person's
            // gesture, so renew the one-use credit before a page action such as a user-only setting
            // write runs after this reply; a script cannot synthesize this AppKit event.
            if picked != nil, let self { AgentPanePersonInput.record(self.model.transport.gestures, sources: self.eventSources) }
            reply(["ok": true, "value": ["picked": picked.map { $0 as Any } ?? NSNull()]])
        }
    }

    /// Pops the menu bar's Customizations menu (CustomizationsMenu.swift, found by its identifier,
    /// since this package does not link the settings window) with its top center at `point`, CSS px
    /// in the page's viewport, on the main queue's next turn so the page call returns first; false
    /// when the menu bar has no such menu.
    func popCustomizationsMenu(at point: CGPoint) -> Bool {
        guard let shown = Self.menuBarSubmenu(NSUserInterfaceItemIdentifier("cmux.menu.customizations"),
                                              in: NSApp.mainMenu) else { return false }
        let local = CGPoint(x: point.x * webView.pageZoom, y: point.y * webView.pageZoom)
        MainDelivery().later { [weak webView] in
            // A view in no window cannot anchor a menu (AppKit raises).
            guard let webView, webView.window != nil else { return }
            let at = webView.isFlipped ? local : CGPoint(x: local.x, y: webView.bounds.height - local.y)
            shown.popUpAtPointer(at, in: webView)
        }
        return true
    }

    private static func menuBarSubmenu(_ id: NSUserInterfaceItemIdentifier, in menu: NSMenu?) -> NSMenu? {
        for item in menu?.items ?? [] {
            if item.identifier == id, let submenu = item.submenu { return submenu }
            if let found = menuBarSubmenu(id, in: item.submenu) { return found }
        }
        return nil
    }

    private func sendPopupEvent(_ event: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        evaluateScript("window.dispatchEvent(new CustomEvent('cmux-popup', {detail: \(String(decoding: data, as: UTF8.self))}))")
    }
}
