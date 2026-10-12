import AppKit
import CmuxNextDesign
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
            popupHostStorage?.hide()
            return ["ok": true, "value": [:] as [String: Any]]
        default:
            return AgentPaneReply.failure(code: "unknown_method", message: "Unknown popup method")
        }
    }

    private func sendPopupEvent(_ event: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        evaluateScript("window.dispatchEvent(new CustomEvent('cmux-popup', {detail: \(String(decoding: data, as: UTF8.self))}))")
    }
}
