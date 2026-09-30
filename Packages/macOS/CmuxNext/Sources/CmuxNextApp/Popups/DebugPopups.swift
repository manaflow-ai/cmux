#if DEBUG
import AppKit
import CmuxNextBrowser
import CmuxNextSettings

/// `debug.popups` (DEBUG builds): the open popup panels, for checks without
/// screenshots. Per panel: the page URL and title, engine, the panel frame
/// (AppKit screen coordinates), key and visible state, the cmux window it
/// floats over, the opener tab, and the panel's child windows (a Chromium
/// page window must sit inside the panel). `{"action": "close"}` closes
/// every panel.
@MainActor
enum DebugPopups {
    static func report(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        if params["action"]?.stringValue == "close" { services.popups.closeAll() }
        return .object(["panels": .array(services.popups.panels.map { panel($0, services: services) })])
    }

    private static func panel(_ panel: BrowserPopupPanel, services: AppServices) -> JSONValue {
        let page = panel.page
        let parent = panel.parent.flatMap { parent in services.windows.controllers.first { $0.window === parent } }
        return .object([
            "url": page.state.url.map { .string($0.absoluteString) } ?? .null,
            "title": .string(panel.title),
            "engine": .string(page.engineKind == .cef ? "chromium" : "webkit"),
            "frame": rect(panel.frame),
            "key": .bool(panel.isKeyWindow),
            "visible": .bool(panel.isVisible),
            "window": parent.map { .string($0.state.id) } ?? .null,
            "opener_tab": services.popups.openerKey(of: page).map { .string($0) } ?? .null,
            "child_windows": .array((panel.childWindows ?? []).map { child in
                .object(["frame": rect(child.frame), "key": .bool(child.isKeyWindow), "visible": .bool(child.isVisible)])
            }),
        ])
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        .object(["x": .number(rect.minX), "y": .number(rect.minY), "width": .number(rect.width), "height": .number(rect.height)])
    }
}
#endif
