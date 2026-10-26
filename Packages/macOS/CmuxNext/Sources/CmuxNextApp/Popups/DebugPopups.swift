#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextBrowser
import CmuxNextPopups
import CmuxNextSettings

/// `debug.popups` (DEBUG builds): the open popup windows (still under the
/// `panels` key, which scripts read), for checks without screenshots. Per
/// window: the page URL and title, engine, the window frame (AppKit screen
/// coordinates), key, visible and miniaturized state, the cmux window that
/// opened it, the opener tab, the traffic lights shown, the location bar's
/// text and whether it shows, and the window's child windows (a Chromium
/// page window must sit inside it). `{"action": "close"}` closes every
/// popup. `{"snapshot_dir": DIR}` also writes each popup window as the
/// window server composited it (with its page) to `DIR/popup-N.png` and
/// reports the path as `snapshot` (an app's own windows need no Screen
/// Recording permission). `icon_picker` is the open icon picker (page, target, anchor,
/// panel frame, key/visible, parent window), or null.
@MainActor
enum DebugPopups {
    static func report(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        if params["action"]?.stringValue == "close" {
            services.popups.closeAll()
            services.iconPicker.open?.provider.finish(.cancel)
        }
        return .object([
            "panels": .array(services.popups.windows.enumerated().map { index, window in
                var entry = popup(window, services: services)
                if let dir = params["snapshot_dir"]?.stringValue, case .object(var fields) = entry {
                    fields["snapshot"] = snapshot(window, to: URL(fileURLWithPath: dir).appendingPathComponent("popup-\(index).png"))
                    entry = .object(fields)
                }
                return entry
            }),
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

    private static func popup(_ panel: BrowserPopupWindow, services: AppServices) -> JSONValue {
        let page = panel.page
        let opener = services.popups.openerWindow(of: panel)
        let parent = opener.flatMap { opener in services.windows.controllers.first { $0.window === opener } }
        let buttons: [(String, NSWindow.ButtonType)] = [("close", .closeButton), ("minimize", .miniaturizeButton), ("zoom", .zoomButton)]
        let lights = buttons.compactMap { name, type in
            panel.standardWindowButton(type).flatMap { $0.isHidden ? nil : JSONValue.string(name) }
        }
        return .object([
            "url": page.state.url.map { .string($0.absoluteString) } ?? .null,
            "title": .string(panel.title),
            "engine": .string(page.engineKind == .cef ? "chromium" : "webkit"),
            "frame": rect(panel.frame),
            "key": .bool(panel.isKeyWindow),
            "visible": .bool(panel.isVisible),
            "miniaturized": .bool(panel.isMiniaturized),
            "child_of_window": .bool(panel.parent != nil),
            "traffic_lights": .array(lights),
            "location_bar": .object([
                "text": .string(panel.addressBar.displayedText),
                "shown": .bool(panel.isToolbarShown),
            ]),
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

    /// Writes `window` (and its page window) as a PNG; the path, or null.
    private static func snapshot(_ window: NSWindow, to url: URL) -> JSONValue {
        guard let image = window.compositedSnapshot(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return .null }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return .string(url.path)
        } catch {
            return .null
        }
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        .object(["x": .number(rect.minX), "y": .number(rect.minY), "width": .number(rect.width), "height": .number(rect.height)])
    }
}
#endif
