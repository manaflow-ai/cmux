import AppKit
import CmuxNextDesign
import CmuxNextSettings

/// `debug.window_list`: every window of the app (`NSApp.windows`), with the
/// popover, panel and sheet windows AppKit makes, so an agent can pick any
/// of them for `debug.window_snapshot` (its `window` param takes the `id`).
///
/// Each entry: `id` (window number), `kind` (the window kit's kind, else
/// `popover`, `sheet`, `panel`, the `cmux.` identifier, or the class name),
/// `title`, `frame` (x, y, width, height in screen points), `visible`, and
/// `parent` (the window number of its sheet parent or parent window, or null).
enum DebugWindowList {
    static func list(services: AppServices) -> JSONValue {
        .object(["windows": .array(NSApp.windows.map { entry($0, services: services) })])
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
