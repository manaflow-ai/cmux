public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// A machine's identity color: the color the person picked for it
/// (`appearance.machineColors`, MachineColorOverrides), else one of the theme's
/// accents, picked by a stable hash of the machine's name (trimmed, lowercased),
/// so each machine keeps one color on every row, tab and chip that names it. The
/// automatic pick is AgentPresenceColor's pick over the name, which the agent
/// pane's machineColor.ts repeats, so the sidebar and the composer chip agree.
public nonisolated struct MachineColor: Sendable {
    /// The machine's name as cmux shows it.
    public let name: String

    public init(name: String) { self.name = name }

    /// The name colors are keyed by: trimmed and lowercased, so "Big-Red " and "big-red" are one machine.
    public var key: String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

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
