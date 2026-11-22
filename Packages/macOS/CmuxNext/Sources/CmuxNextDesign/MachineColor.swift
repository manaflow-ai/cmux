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

    /// The color as text drawn on `grounds` (the surfaces the name can show on): its hue, moved
    /// toward black or white only as far as it takes to read at 4.5:1 on every ground. A person's
    /// `#FFFF00` read 1.1:1 on a light theme as it was; a color that already reads is kept. Where no
    /// color reaches 4.5:1 on every ground (Grass's pressed row, 4.41:1 at most), it is the pole
    /// that reads best on the worst ground.
    /// - Parameters:
    ///   - tokens: the theme's tokens.
    ///   - overrides: the person's picks.
    ///   - grounds: the opaque surfaces under the text.
    /// - Returns: the text color.
    public func textRGB(tokens: ThemeTokens, overrides: MachineColorOverrides, on grounds: [ThemeRGB]) -> ThemeRGB {
        let fitted = CmuxDialogButtonLook.readable(rgb(tokens: tokens, overrides: overrides).withAlpha(1), over: grounds,
                                                   minimum: ThemeTokens.minimumTextContrast)
        let worst = { (ink: ThemeRGB) in grounds.map { ink.contrast(with: $0) }.min() ?? .infinity }
        guard worst(fitted) < ThemeTokens.minimumTextContrast else { return fitted }
        // The fit runs ground by ground, so on grounds that pull apart it can stop at the weaker pole.
        return [ThemeRGB.white, .black].reduce(fitted) { worst($1) > worst($0) ? $1 : $0 }
    }

    /// The rows a machine's name sits on: the bare row and the hovered, selected and pressed one.
    public static func rowGrounds(_ tokens: ThemeTokens) -> [ThemeRGB] {
        let row = tokens.windowBackground.withAlpha(1)
        return [row, tokens.hoverFill.composited(over: row), tokens.selectionFill.composited(over: row), tokens.pressedFill.composited(over: row)]
    }

    /// The color as text on a row (``rowGrounds(_:)``) in the active theme scope, with the person's picks.
    @MainActor public var rowTextColor: NSColor {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        return textRGB(tokens: tokens, overrides: (ThemeContext.activeScope ?? ThemeScope.app).store.machineColors,
                       on: Self.rowGrounds(tokens)).nsColor
    }

    /// The person's pick as text on a row in the active theme scope; nil without a pick.
    @MainActor public var pickedRowTextColor: NSColor? {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let overrides = (ThemeContext.activeScope ?? ThemeScope.app).store.machineColors
        guard overrides.rgb(forKey: key, tokens: tokens) != nil else { return nil }
        return textRGB(tokens: tokens, overrides: overrides, on: Self.rowGrounds(tokens)).nsColor
    }

    /// The person's pick as text on an overlay card (a hover card): the card's tint over the worst
    /// desktop for the theme, as ``ThemeElementAudit`` checks popover text, and the solid popup
    /// surface. nil without a pick.
    @MainActor public var pickedCardTextColor: NSColor? {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let overrides = (ThemeContext.activeScope ?? ThemeScope.app).store.machineColors
        guard overrides.rgb(forKey: key, tokens: tokens) != nil else { return nil }
        let lift = ChromeTunables.opaqueOverlayLift.value
        // glass-opaque-allow: a contrast reference only (the card ThemeElementAudit measures popover text on); nothing paints it here
        let card = CardMaterial(tokens, lift: lift, minimumOpacity: ChromeTunables.cardOpacity.value)
        // glass-opaque-allow: contrast references only (the card over the worst desktop, the Reduce Transparency surface); nothing paints them here
        let grounds = [card.tint.composited(over: tokens.isDark ? .white : .black), tokens.opaqueOverlayFill(lift: lift)]
        return textRGB(tokens: tokens, overrides: overrides, on: grounds).nsColor
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
