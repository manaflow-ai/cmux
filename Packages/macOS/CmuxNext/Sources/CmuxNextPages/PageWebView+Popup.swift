import AppKit
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextSettings
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
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
        let host = popupHost ?? makePopupHost()
        popupHost = host
        if op == PageNativeOp.popupUpdate {
            host.update(model)
            return .object([:])
        }
        return JSONValue(foundation: host.show(model)) ?? .object(["shown": .bool(false)])
    }

    /// The page's popup host, made on first use: while its menu shows, the page holds its `popup`
    /// keep reason (one begin at the show, one end at the hide, pick or dismiss).
    private func makePopupHost() -> WebPopupHost {
        let host = WebPopupHost(
            webView: focusView, zoom: { [weak self] in CGFloat(self?.pageZoom ?? 1) },
            send: { [weak self] event in self?.router.publishPopup(JSONValue(foundation: event) ?? .null) })
        host.hoverFrameInput = popupHoverFrameInput
        let keep = keepReasons
        host.onShownChange = { shown in
            if shown { keep.begin(.popup) } else { keep.end(.popup) }
        }
        return host
    }

    /// A right-click menu of the page (`cmux.app.contextMenu.show`) as a standard macOS menu at the
    /// pointer; answers the chosen row's id once it closes.
    func contextMenu(_ params: [String: Any]) async -> JSONValue {
        guard let menu = WebContextMenu(params) else { return .object(["picked": .null]) }
        // The menu is up until it closes: the page's `popup` keep reason.
        keepReasons.begin(.popup)
        defer { keepReasons.end(.popup) }
        let picked: String? = try? await withOnceContinuation { (continuation: OnceContinuation<String?, OnceContinuationError>) in
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
