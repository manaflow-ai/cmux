/// `ui.paneAnimations` in cmux.json: whether pane layout changes animate
/// (plans/cmux-next/motion.md, "Pane layout motion"). Off by default
/// (Lawrence 2026-10-14: "get rid of big animations by default for the
/// panes"): a split, close, move, swap, zoom, column reveal or screen switch
/// applies in one frame. On restores the springs. `ui.animationSpeed` "off"
/// and Reduce Motion still snap them.
nonisolated extension CmuxConfigSnapshot {
    public static let paneAnimationsPath = ["ui", "paneAnimations"]
    public static let paneAnimationsFallback = false

    /// Absent is off; a value that is not a bool is off plus a diagnostic.
    static func parsePaneAnimations(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: paneAnimationsPath) else { return (paneAnimationsFallback, nil) }
        guard let enabled = value.boolValue else {
            return (paneAnimationsFallback, SettingsDiagnostic(kind: .invalidValue, path: "ui.paneAnimations", message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
