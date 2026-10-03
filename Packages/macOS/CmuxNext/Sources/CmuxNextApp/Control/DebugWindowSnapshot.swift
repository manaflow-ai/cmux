import AppKit
import CmuxNextDesign
import CmuxNextSettings

/// `debug.window_snapshot`: one of this app's own windows rendered through
/// AppKit (`NSWindow.renderSnapshot`), so agents get screenshots on hosts
/// without Screen Recording permission. Metal content (terminals,
/// Chromium) and Liquid Glass blur differ from the screen
/// (plans/cmux-next/windows.md).
///
/// Params: `window` (a main window id, or any window's number from
/// `debug.window_list`: popovers, panels and sheets too), or `kind`
/// (a `WindowKind` raw value: `main`, `settings`, `debugSettings`,
/// `appStore`, `onboarding`, ...);
/// default the key window, else the active main window. `path` is the PNG
/// to write (default a file in the temporary directory). Returns `path`,
/// `width`, `height` (pixels), `kind` and `window_number`.
enum DebugWindowSnapshot {
    static func capture(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let window = window(params, services: services) else { return .object(["error": .string("no such window")]) }
        let kind = kind(of: window, services: services)
        let path = params["path"]?.stringValue.map { ($0 as NSString).expandingTildeInPath }
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-window-\(kind)-\(window.windowNumber).png")
        do {
            let size = try window.writeSnapshot(to: URL(fileURLWithPath: path))
            return .object([
                "path": .string(path), "width": JSONValue(Int(size.width)), "height": JSONValue(Int(size.height)),
                "kind": .string(kind), "window_number": JSONValue(window.windowNumber),
            ])
        } catch {
            return .object(["error": .string("snapshot failed: \(error.localizedDescription)")])
        }
    }

    /// The window `params` names.
    static func window(_ params: [String: JSONValue], services: AppServices) -> NSWindow? {
        let windows = NSApp.windows
        if let id = params["window"]?.stringValue ?? params["window"]?.intValue.map(String.init) {
            if let main = services.windows.controller(for: id)?.window { return main }
            return windows.first { String($0.windowNumber) == id }
        }
        if let kind = params["kind"]?.stringValue {
            if kind == "main" { return services.windows.active?.window }
            return windows.first { $0.isVisible && Self.kind(of: $0, services: services) == kind }
        }
        return NSApp.keyWindow ?? services.windows.active?.window
    }

    /// The window's kind as `debug.window_list` names it.
    static func kind(of window: NSWindow, services: AppServices) -> String {
        DebugWindowList.kind(of: window, services: services)
    }
}
