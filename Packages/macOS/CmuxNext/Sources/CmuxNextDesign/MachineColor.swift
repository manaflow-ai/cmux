public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// A machine's color in a theme's palette (``MachineColor``).
nonisolated extension MachineColor {
    /// The color in `tokens`' palette: the pick in `overrides`, else the automatic one.
    public func rgb(tokens: ThemeTokens, overrides: MachineColorOverrides) -> ThemeRGB {
        overrides.rgb(forKey: key, tokens: tokens) ?? AgentPresenceColor(key: key).rgb(tokens: tokens)
    }

    /// The color in the active theme scope, with the person's picks (`ThemeStore.machineColors`).
    @MainActor public var color: NSColor {
        rgb(tokens: ThemeContext.active ?? ThemeScope.app.tokens, overrides: (ThemeContext.activeScope ?? ThemeScope.app).store.machineColors).nsColor
    }

    /// The person's pick for this machine in the active theme scope; nil without one. For marks
    /// that stay quiet unless the person colored the machine (a tab's machine badge).
    @MainActor public var pickedColor: NSColor? {
        (ThemeContext.activeScope ?? ThemeScope.app).store.machineColors.rgb(forKey: key, tokens: ThemeContext.active ?? ThemeScope.app.tokens)?.nsColor
    }
}
