#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings
import CmuxNextTerminal

/// `debug.appearance` (DEBUG builds): overrides this app's own appearance
/// (`NSApp.appearance`) so a test can switch light and dark without touching
/// the system setting. The terminal theme follows it like the system
/// appearance: Ghostty's color scheme (a light/dark theme such as the
/// default Apple System Colors), the chrome derived from it, and room,
/// workspace and terminal themes. Params: `mode` `light`, `dark`, or
/// `system` (clears the override). Returns the effective appearance, the
/// applied terminal background (`#RRGGBB`, as applied when the call returns;
/// poll `debug.themes` to wait for a reload), and this app bundle's Ghostty
/// themes folder: null there means the bundle ships no themes, so without
/// Ghostty.app every theme is Ghostty's built-in default and light captures
/// stay dark.
enum DebugAppearance {
    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["mode"]?.stringValue {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "system": NSApp.appearance = nil
        default: break
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = GhosttyRuntime.shared.themeColors.map {
            JSONValue.string(String(format: "#%02X%02X%02X", $0.background.r, $0.background.g, $0.background.b))
        } ?? .null
        // The app's own copy only: resourcesDirectory() also falls back to Ghostty.app.
        let themes = Bundle.main.resourceURL.map { $0.appending(path: "ghostty/themes").path }
            .flatMap { FileManager.default.fileExists(atPath: $0) ? JSONValue.string($0) : nil }
        return .object([
            "override": NSApp.appearance.map { .string($0.name.rawValue) } ?? .null,
            "effective": .string(dark ? "dark" : "light"),
            "terminal_background": background,
            "themes": themes ?? .null,
        ])
    }
}
#endif
