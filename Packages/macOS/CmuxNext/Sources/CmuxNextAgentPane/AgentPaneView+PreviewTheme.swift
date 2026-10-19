#if DEBUG
import CmuxNextDesign
package import CmuxNextSettings

extension AgentPaneView {
    /// Temporarily applies a fixture theme for preview evidence, or restores inheritance.
    package func previewTheme(_ mode: String?, pane: String) -> JSONValue {
        // A controlled pane theme for native preview evidence despite fixed Ghostty colors.
        let mode = mode ?? "reset"
        guard ["light", "dark", "reset"].contains(mode) else {
            return .object(["error": .string("mode must be light, dark or reset")])
        }
        var input = themeScope.input
        input.background = mode == "light" ? ThemeRGB(red: 0.98, green: 0.98, blue: 0.98) : ThemeRGB(red: 0.1, green: 0.1, blue: 0.1)
        input.foreground = mode == "light" ? ThemeRGB(red: 0.1, green: 0.1, blue: 0.1) : ThemeRGB(red: 0.9, green: 0.9, blue: 0.9)
        themeScope.setOverride(mode == "reset" ? nil : ThemeSpec("preview-fixture"), input: mode == "reset" ? nil : input, animated: false)
        applyTheme()
        return .object(["pane": .string(pane), "mode": .string(mode)])
    }
}
#endif
