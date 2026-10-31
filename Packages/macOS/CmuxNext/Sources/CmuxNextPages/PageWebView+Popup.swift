import AppKit
import CmuxNextDesign
import CmuxNextSettings
import Foundation

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
            send: { [weak self] event in self?.popupEvent(event) })
        popupHost = host
        if op == PageNativeOp.popupUpdate {
            host.update(model)
            return .object([:])
        }
        return JSONValue(foundation: host.show(model)) ?? .object(["shown": .bool(false)])
    }

    /// One event of the native popup for the page (`pick`, `highlight`, `dismiss`). A pick is a
    /// choice in the host's own panel, which is a window of its own: the page's gesture monitors never
    /// see that click, so the choice itself is the gesture, as a right-click menu's is
    /// (``finishContextMenu(_:at:)``). The host hears it first (``onPopupPick``, with the AppKit event
    /// being dispatched), before the page runs the row's action.
    func popupEvent(_ event: [String: Any], current: NSEvent? = NSApp.currentEvent) {
        if event["type"] as? String == "pick" {
            let uptime = ProcessInfo.processInfo.systemUptime
            if chromiumSession != nil { chromiumUserInput(at: uptime) }
            else { webView.noteNativeMenuSelection(at: uptime) }
            onPopupPick?(current)
        }
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

    /// Completes the host's native menu, whose nonnil result comes only from an AppKit choice.
    func finishContextMenu(_ picked: String?, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> JSONValue {
        // PageRouter cancels the old call on close/rebind; its menu cannot authorize the next page.
        guard !Task.isCancelled else { return .object(["picked": .null]) }
        if picked != nil {
            // The menu can stay open longer than the opener's gesture lifetime. Its real choice
            // backs the page call that follows; dismissal and script parameters grant nothing.
            if chromiumSession != nil { chromiumUserInput(at: uptime) }
            else { webView.noteNativeMenuSelection(at: uptime) }
        }
        return .object(["picked": picked.map(JSONValue.string) ?? .null])
    }
}
