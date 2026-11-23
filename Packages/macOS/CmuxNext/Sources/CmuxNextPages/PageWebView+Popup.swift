public import AppKit
import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// A small transient surface of the page with no room in it shows past the window's edge
/// (cx-6k6cg, ``WebPopupHost``): `cmux.app.popup.show`, `update` and `hide` from the page; the
/// host's `pick`, `highlight` and `dismiss` go back on the page's `cmux.page.popup` stream.
extension PageWebView {
    func popup(_ op: String, params: [String: Any]) -> JSONValue {
        if op == PageNativeOp.popupHide {
            popupHost?.hideRequest(params)
            return .object([:])
        }
        guard let model = WebPopupHost.Model(params) else { return .object(["shown": .bool(false)]) }
        let host = popupHost ?? WebPopupHost(
            webView: focusView, zoom: { [weak self] in CGFloat(self?.pageZoom ?? 1) },
            send: { [weak self] event in self?.publishPopupEvent(event) })
        popupHost = host
        if op == PageNativeOp.popupUpdate {
            host.update(model)
            return .object([:])
        }
        return JSONValue(foundation: host.show(model)) ?? .object(["shown": .bool(false)])
    }

    /// A host popup's `pick` comes only from a real AppKit row choice (``WebPopupHost``), so it backs
    /// the page call that follows like a native context-menu choice; other events grant nothing.
    func publishPopupEvent(_ event: [String: Any], at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if event["type"] as? String == "pick" { noteNativeChoice(at: uptime) }
        router.publishPopup(JSONValue(foundation: event) ?? .null)
    }

    /// A right-click menu of the page (`cmux.app.contextMenu.show`) as a standard macOS menu at the
    /// pointer; answers the chosen row's id once it closes.
    func contextMenu(_ params: [String: Any]) async -> JSONValue {
        guard let menu = WebContextMenu(params) else { return .object(["picked": .null]) }
        let picked: String? = await withCheckedContinuation { continuation in
            menu.present(in: focusView, zoom: CGFloat(pageZoom)) { continuation.resume(returning: $0) }
        }
        return finishContextMenu(picked)
    }

    /// Shows an app-made menu (an action registry's rows) at a page point in CSS pixels, as
    /// ``contextMenu(_:)`` places its own, and returns once it closes. A page in no window shows none.
    public func presentMenu(_ menu: NSMenu, atPagePoint point: CGPoint) async {
        await PageMenuPresenter.present(menu, at: CGPoint(x: point.x * CGFloat(pageZoom), y: point.y * CGFloat(pageZoom)), in: focusView)
    }

    /// Completes the host's native menu, whose nonnil result comes only from an AppKit choice.
    func finishContextMenu(_ picked: String?, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> JSONValue {
        // PageRouter cancels the old call on close/rebind; its menu cannot authorize the next page.
        guard !Task.isCancelled else { return .object(["picked": .null]) }
        if picked != nil {
            // The menu can stay open longer than the opener's gesture lifetime. Its real choice
            // backs the page call that follows; dismissal and script parameters grant nothing.
            noteNativeChoice(at: uptime)
        }
        return .object(["picked": picked.map(JSONValue.string) ?? .null])
    }

    private func noteNativeChoice(at uptime: TimeInterval) {
        if chromiumSession != nil { chromiumUserInput(at: uptime) }
        else { webView.noteNativeMenuSelection(at: uptime) }
    }
}
