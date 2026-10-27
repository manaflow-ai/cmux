import AppKit
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextSettings

/// `debug.window_list`: every window of the app (`NSApp.windows`), with the
/// popover, panel and sheet windows AppKit makes, so an agent can pick any
/// of them for `debug.window_snapshot` (its `window` param takes the `id`).
///
/// Each entry: `id` (window number), `kind` (the window kit's kind, else
/// `popover`, `sheet`, `panel`, the `cmux.` identifier, or the class name),
/// `title`, `frame` (x, y, width, height in screen points), `visible`,
/// `parent` (the window number of its sheet parent or parent window, or null),
/// `class`, `level`, `ignores_mouse`, `key`, `alpha` (Chromium popup windows) and
/// `chromium_page` (a Chromium page window over a cmux window: in process only).
/// `hosted_pages`: the context ids of the Chromium pages shown as hosted views in a
/// pane (host mode), which have no window of their own.
enum DebugWindowList {
    static func list(services: AppServices) -> JSONValue {
        .object(["windows": .array(NSApp.windows.map { entry($0, services: services) }), "hosted_pages": .array(hostedPages(services))])
    }

    /// The context id each hosted page view of a shown Chromium tab shows, window by window.
    private static func hostedPages(_ services: AppServices) -> [JSONValue] {
        services.windows.controllers.flatMap { controller in
            (controller.content?.panes.values.map { $0 } ?? []).compactMap { pane -> JSONValue? in
                guard let tab = pane.currentContent?.chromiumTab, tab.presentation == .inView,
                      let page = ChromiumHostPageView.first(in: tab.contentView) else { return nil }
                return .object(["window": .string(controller.state.id), "pane": .string(pane.paneKey),
                                "context_id": .number(Double(page.shownContextID)), "takes_input": .bool(page.takesPageInput)])
            }
        }
    }

    static func entry(_ window: NSWindow, services: AppServices) -> JSONValue {
        let frame = window.frame
        let parent = window.sheetParent ?? window.parent
        return .object([
            "id": JSONValue(window.windowNumber),
            "kind": .string(kind(of: window, services: services)),
            "title": .string(window.title),
            "frame": .object([
                "x": .number(frame.minX), "y": .number(frame.minY), "width": .number(frame.width), "height": .number(frame.height),
            ]),
            "visible": .bool(window.isVisible),
            "parent": parent.map { JSONValue($0.windowNumber) } ?? .null,
            "class": .string(String(describing: type(of: window))),
            "level": JSONValue(window.level.rawValue),
            "ignores_mouse": .bool(window.ignoresMouseEvents),
            "key": .bool(window.isKeyWindow),
            // On screen and not covered (AppKit's occlusion), and in the Dock: whether a bench window could be seen.
            "occluded": .bool(!window.occlusionState.contains(.visible)),
            "miniaturized": .bool(window.isMiniaturized),
            "alpha": .number(Double(window.alphaValue)),
            "chromium_page": .bool(WindowOverlayHost.isPageWindow(window)),
        ])
    }

    /// The window kit's kind, else what AppKit made the window for.
    static func kind(of window: NSWindow, services: AppServices) -> String {
        if let kind = window.windowKind { return kind.rawValue }
        if services.windows.controllers.contains(where: { $0.window === window }) { return WindowKind.main.rawValue }
        let className = String(describing: type(of: window))
        if className.contains("Popover") { return "popover" }
        if window.sheetParent != nil { return "sheet" }
        if let id = window.identifier?.rawValue, id.hasPrefix("cmux.") { return String(id.dropFirst("cmux.".count)) }
        if window is NSPanel { return "panel" }
        return className
    }
}
