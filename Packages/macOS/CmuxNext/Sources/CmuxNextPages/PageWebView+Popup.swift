import AppKit
import CmuxNextDesign
import CmuxNextSettings

/// A small transient surface of the page with no room in it shows past the window's edge
/// (cx-6k6cg, ``WebPopupHost``): `cmux.app.popup.show`, `update` and `hide` from the page; the
/// host's `pick`, `highlight` and `dismiss` go back on the page's `cmux.page.popup` stream.
extension PageWebView {
    func popup(_ op: String, params: [String: Any]) -> JSONValue {
        if op == PageNativeOp.popupHide {
            popupHost?.hide()
            return .object([:])
        }
        guard let model = WebPopupHost.Model(params) else { return .object(["shown": .bool(false)]) }
        let host = popupHost ?? WebPopupHost(
            webView: focusView, zoom: { [weak self] in CGFloat(self?.pageZoom ?? 1) },
            send: { [weak self] event in self?.router.publishPopup(JSONValue(foundation: event) ?? .null) })
        popupHost = host
        if op == PageNativeOp.popupUpdate {
            host.update(model)
            return .object([:])
        }
        return JSONValue(foundation: host.show(model)) ?? .object(["shown": .bool(false)])
    }
}
