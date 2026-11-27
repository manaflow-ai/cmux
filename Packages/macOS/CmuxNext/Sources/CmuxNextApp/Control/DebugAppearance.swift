#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings
import CmuxNextTerminal

/// `debug.appearance` (DEBUG builds): overrides this app's own appearance
/// (`NSApp.appearance`) so a test can switch light and dark without touching
/// the system setting; the terminal theme follows it like the system
/// appearance. Params: `mode` `light`, `dark`, or `system` (clears the
/// override). Returns the effective appearance and the applied terminal
/// background (`#RRGGBB`; poll `debug.themes` to wait for a reload). A read
/// (no `mode`) also names this bundle's Ghostty themes folder (null: no
/// themes, so light captures stay dark). A switch never names a path: its
/// answer goes in a capture's report, whose privacy check refuses one.
enum DebugAppearance {
    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        // The same switch as the appearance.mode setting, without writing cmux.json.
        if let mode = params["mode"]?.stringValue.flatMap(AppearanceMode.init(rawValue:)) { AppearanceModeSetting.apply(mode) }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = GhosttyRuntime.shared.themeColors.map {
            JSONValue.string(String(format: "#%02X%02X%02X", $0.background.r, $0.background.g, $0.background.b))
        } ?? .null
        // The app's own copy only: resourcesDirectory() also falls back to Ghostty.app.
        let themes = Bundle.main.resourceURL.map { $0.appending(path: "ghostty/themes").path }
            .flatMap { FileManager.default.fileExists(atPath: $0) ? JSONValue.string($0) : nil }
        var answer: [String: JSONValue] = ["override": NSApp.appearance.map { .string($0.name.rawValue) } ?? .null,
                                           "effective": .string(dark ? "dark" : "light"), "terminal_background": background]
        if params["mode"] == nil { answer["themes"] = themes ?? .null }
        return .object(answer)
    }
}
#endif
