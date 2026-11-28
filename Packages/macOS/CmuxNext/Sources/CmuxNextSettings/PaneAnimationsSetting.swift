/// `ui.paneAnimations` in cmux.json: whether pane layout changes animate
/// (plans/cmux-next/motion.md, "Pane layout motion"). On by default (Lawrence
/// 2026-10-16: "We want animations on by default but then we can let people
/// configure it to disable the animations completely"): a split, close, move,
/// swap, zoom, column reveal or screen switch springs. False applies them in one
/// frame; `ui.animationSpeed` "off" and Reduce Motion stop every animation.
public nonisolated struct PaneAnimationsSetting {
    public nonisolated init() {}
    public static let configPath = ["ui", "paneAnimations"]
    public static let fallback = true

    /// Absent is on; a value that is not a bool is on plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "ui.paneAnimations", message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
