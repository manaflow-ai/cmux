#if DEBUG
import AppKit
import CmuxNextBrowser
import CmuxNextSettings

/// `debug.popups` (DEBUG builds): the open popup panels, for checks without
/// screenshots. Per panel: the page URL and title, engine, the panel frame
/// (AppKit screen coordinates), key and visible state, the cmux window it
/// floats over, the opener tab, and the panel's child windows (a Chromium
/// page window must sit inside the panel). `{"action": "close"}` closes
/// every panel. `icon_picker` is the open icon picker (page, target, anchor,
/// panel frame, key/visible, parent window), or null.
@MainActor
enum DebugPopups {
    static func report(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        if params["action"]?.stringValue == "close" {
            services.popups.closeAll()
            services.iconPicker.open?.provider.finish(.cancel)
        }
        return .object([
            "panels": .array(services.popups.panels.map { panel($0, services: services) }),
            "icon_picker": iconPicker(services),
        ])
    }

    private static func iconPicker(_ services: AppServices) -> JSONValue {
        guard let open = services.iconPicker.open else { return .null }
        let parent = open.parent.flatMap { parent in services.windows.controllers.first { $0.window === parent } }
        return .object([
            "page": .string(open.page.pageID),
            "target": .string(open.target),
            "anchor": rect(open.anchor),
            "frame": rect(open.panel.frame),
            "key": .bool(open.panel.isKeyWindow),
            "visible": .bool(open.panel.isVisible),
            "window": parent.map { .string($0.state.id) } ?? .null,
        ])
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
            "views": .array(panel.contentView.map { views($0, depth: 0) } ?? []),
        ])
    }

    /// The panel's view tree (class, frame in the window, hidden), to see
    /// where the page view sits and whether it has a size.
    private static func views(_ view: NSView, depth: Int) -> [JSONValue] {
        var out: [JSONValue] = [.object([
            "depth": .number(Double(depth)), "class": .string(String(describing: type(of: view))),
            "frame": rect(view.convert(view.bounds, to: nil)), "hidden": .bool(view.isHidden),
        ])]
        if depth < 12 { for sub in view.subviews { out += views(sub, depth: depth + 1) } }
        return out
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        .object(["x": .number(rect.minX), "y": .number(rect.minY), "width": .number(rect.width), "height": .number(rect.height)])
    }
}
#endif
