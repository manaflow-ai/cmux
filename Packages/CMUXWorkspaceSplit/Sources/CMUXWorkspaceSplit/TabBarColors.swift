import SwiftUI
import AppKit

/// Native macOS colors for the tab bar
enum TabBarColors {
    enum Constants {
        static let darkTextAlpha: CGFloat = 0.82
        static let darkSecondaryTextAlpha: CGFloat = 0.62
        static let darkTertiaryTextAlpha: CGFloat = 0.35
        static let lightTextAlpha: CGFloat = 0.82
        static let lightSecondaryTextAlpha: CGFloat = 0.68
        static let lightTertiaryTextAlpha: CGFloat = 0.35
    }

    static func chromeBackgroundColor(
        for appearance: WorkspaceLayoutConfiguration.Appearance
    ) -> NSColor? {
        guard let value = appearance.chromeColors.backgroundHex else { return nil }
        return NSColor(workspaceSplitHex: value)
    }

    static func paneBackgroundColor(
        for appearance: WorkspaceLayoutConfiguration.Appearance
    ) -> NSColor? {
        guard let value = appearance.chromeColors.paneBackgroundHex else {
            return chromeBackgroundColor(for: appearance)
        }
        return NSColor(workspaceSplitHex: value)
    }

    static func tabBarBackgroundColor(
        for appearance: WorkspaceLayoutConfiguration.Appearance
    ) -> NSColor? {
        guard let value = appearance.chromeColors.tabBarBackgroundHex else {
            return chromeBackgroundColor(for: appearance)
        }
        return NSColor(workspaceSplitHex: value)
    }

    static func splitButtonBackdropColor(
        for appearance: WorkspaceLayoutConfiguration.Appearance
    ) -> NSColor? {
        guard let value = appearance.chromeColors.splitButtonBackdropHex else {
            return tabBarBackgroundColor(for: appearance)
        }
        return NSColor(workspaceSplitHex: value)
    }

    static func nonClearColor(_ color: NSColor?) -> NSColor? {
        guard let color else { return nil }
        let resolved = color.usingColorSpace(.sRGB) ?? color
        return resolved.alphaComponent <= 0.001 ? nil : resolved
    }

    static func semanticTabBarBackgroundColor(
        for appearance: WorkspaceLayoutConfiguration.Appearance
    ) -> NSColor? {
        nonClearColor(tabBarBackgroundColor(for: appearance))
            ?? nonClearColor(chromeBackgroundColor(for: appearance))
    }

    static func chromeBorderColor(
        for appearance: WorkspaceLayoutConfiguration.Appearance
    ) -> NSColor? {
        guard let value = appearance.chromeColors.borderHex else { return nil }
        return NSColor(workspaceSplitHex: value)
    }

    static func effectiveBackgroundColor(
        for appearance: WorkspaceLayoutConfiguration.Appearance,
        fallback fallbackColor: NSColor
    ) -> NSColor {
        chromeBackgroundColor(for: appearance) ?? fallbackColor
    }

    static func effectiveTextColor(
        for appearance: WorkspaceLayoutConfiguration.Appearance,
        secondary: Bool
    ) -> NSColor {
        guard let custom = semanticTabBarBackgroundColor(for: appearance) else {
            return secondary ? .secondaryLabelColor : .labelColor
        }

        if custom.isWorkspaceLayoutLightColor {
            let alpha = secondary ? Constants.darkSecondaryTextAlpha : Constants.darkTextAlpha
            return NSColor.black.withAlphaComponent(alpha)
        }

        let alpha = secondary ? Constants.lightSecondaryTextAlpha : Constants.lightTextAlpha
        return NSColor.white.withAlphaComponent(alpha)
    }

    static func effectiveInactiveSelectedIndicatorColor(
        for appearance: WorkspaceLayoutConfiguration.Appearance
    ) -> NSColor {
        guard let custom = chromeBackgroundColor(for: appearance) else {
            return .tertiaryLabelColor
        }

        if custom.isWorkspaceLayoutLightColor {
            return NSColor.black.withAlphaComponent(Constants.darkTertiaryTextAlpha)
        }

        return NSColor.white.withAlphaComponent(Constants.lightTertiaryTextAlpha)
    }

    static func paneBackground(for appearance: WorkspaceLayoutConfiguration.Appearance) -> Color {
        Color(nsColor: nsColorPaneBackground(for: appearance))
    }

    static func nsColorPaneBackground(for appearance: WorkspaceLayoutConfiguration.Appearance) -> NSColor {
        paneBackgroundColor(for: appearance) ?? .textBackgroundColor
    }

    // MARK: - Tab Bar Background

    static var barBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static func barBackground(for appearance: WorkspaceLayoutConfiguration.Appearance) -> Color {
        Color(nsColor: nsColorBarBackground(for: appearance))
    }

    static func nsColorBarBackground(for appearance: WorkspaceLayoutConfiguration.Appearance) -> NSColor {
        tabBarBackgroundColor(for: appearance)
            ?? effectiveBackgroundColor(for: appearance, fallback: .windowBackgroundColor)
    }

    static func nsColorChromeBackground(for appearance: WorkspaceLayoutConfiguration.Appearance) -> NSColor {
        effectiveBackgroundColor(for: appearance, fallback: .windowBackgroundColor)
    }

    static func nsColorSplitButtonBackdropSurface(for appearance: WorkspaceLayoutConfiguration.Appearance) -> NSColor {
        splitButtonBackdropColor(for: appearance) ?? nsColorBarBackground(for: appearance)
    }

    static func nsColorSplitButtonBackdrop(
        for appearance: WorkspaceLayoutConfiguration.Appearance,
        focused: Bool = true
    ) -> NSColor {
        precompositedPaneBackground(for: appearance, focused: focused)
    }

    static func shouldPaintSplitButtonBackdrop(for appearance: WorkspaceLayoutConfiguration.Appearance) -> Bool {
        splitButtonBackdropColor(for: appearance) != nil
            || tabBarBackgroundColor(for: appearance) != nil
            || chromeBackgroundColor(for: appearance) != nil
    }

    static var barMaterial: Material {
        .bar
    }

    // MARK: - Tab States

    static var activeTabBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static func activeTabBackground(for appearance: WorkspaceLayoutConfiguration.Appearance) -> Color {
        guard let custom = tabBarBackgroundColor(for: appearance) else {
            return activeTabBackground
        }
        if appearance.usesSharedBackdrop {
            let semanticBackground = semanticTabBarBackgroundColor(for: appearance) ?? custom
            let overlayColor = semanticBackground.isWorkspaceLayoutLightColor
                ? NSColor.black.withAlphaComponent(0.06)
                : NSColor.white.withAlphaComponent(0.08)
            return Color(nsColor: overlayColor)
        }
        let adjusted = custom.isWorkspaceLayoutLightColor
            ? custom.workspaceSplitDarken(by: 0.065)
            : custom.workspaceSplitLighten(by: 0.12)
        return Color(nsColor: adjusted)
    }

    static var hoveredTabBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.5)
    }

    static func hoveredTabBackground(for appearance: WorkspaceLayoutConfiguration.Appearance) -> Color {
        guard let custom = tabBarBackgroundColor(for: appearance) else {
            return hoveredTabBackground
        }
        if appearance.usesSharedBackdrop {
            let semanticBackground = semanticTabBarBackgroundColor(for: appearance) ?? custom
            let overlayColor = semanticBackground.isWorkspaceLayoutLightColor
                ? NSColor.black.withAlphaComponent(0.055)
                : NSColor.white.withAlphaComponent(0.075)
            return Color(nsColor: overlayColor)
        }
        let adjusted = custom.isWorkspaceLayoutLightColor
            ? custom.workspaceSplitDarken(by: 0.03)
            : custom.workspaceSplitLighten(by: 0.07)
        return Color(nsColor: adjusted.withAlphaComponent(0.78))
    }

    static var inactiveTabBackground: Color {
        .clear
    }

    // MARK: - Text Colors

    static var activeText: Color {
        Color(nsColor: .labelColor)
    }

    static func activeText(for appearance: WorkspaceLayoutConfiguration.Appearance) -> Color {
        Color(nsColor: effectiveTextColor(for: appearance, secondary: false))
    }

    static func nsColorActiveText(for appearance: WorkspaceLayoutConfiguration.Appearance) -> NSColor {
        effectiveTextColor(for: appearance, secondary: false)
    }

    static var inactiveText: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    static func inactiveText(for appearance: WorkspaceLayoutConfiguration.Appearance) -> Color {
        Color(nsColor: effectiveTextColor(for: appearance, secondary: true))
    }

    static func nsColorInactiveText(for appearance: WorkspaceLayoutConfiguration.Appearance) -> NSColor {
        effectiveTextColor(for: appearance, secondary: true)
    }

    static func splitActionIcon(for appearance: WorkspaceLayoutConfiguration.Appearance, isPressed: Bool) -> Color {
        Color(nsColor: nsColorSplitActionIcon(for: appearance, isPressed: isPressed))
    }

    static func nsColorSplitActionIcon(
        for appearance: WorkspaceLayoutConfiguration.Appearance,
        isPressed: Bool
    ) -> NSColor {
        isPressed ? nsColorActiveText(for: appearance) : nsColorInactiveText(for: appearance)
    }

    // MARK: - Borders & Indicators

    static var separator: Color {
        Color(nsColor: .separatorColor)
    }

    static func separator(for appearance: WorkspaceLayoutConfiguration.Appearance) -> Color {
        Color(nsColor: nsColorSeparator(for: appearance))
    }

    static func nsColorSeparator(for appearance: WorkspaceLayoutConfiguration.Appearance) -> NSColor {
        if let explicit = chromeBorderColor(for: appearance) {
            return explicit
        }

        guard let custom = tabBarBackgroundColor(for: appearance) else {
            return .separatorColor
        }
        let alpha: CGFloat = custom.isWorkspaceLayoutLightColor ? 0.26 : 0.36
        let tone = custom.isWorkspaceLayoutLightColor
            ? custom.workspaceSplitDarken(by: 0.12)
            : custom.workspaceSplitLighten(by: 0.16)
        return tone.withAlphaComponent(alpha)
    }

    static func selectedIndicator(
        for appearance: WorkspaceLayoutConfiguration.Appearance,
        focused: Bool
    ) -> Color {
        Color(nsColor: nsColorSelectedIndicator(for: appearance, focused: focused))
    }

    static func nsColorSelectedIndicator(
        for appearance: WorkspaceLayoutConfiguration.Appearance,
        focused: Bool
    ) -> NSColor {
        if focused {
            return .controlAccentColor
        }

        return effectiveInactiveSelectedIndicatorColor(for: appearance)
    }

    static var dropIndicator: Color {
        Color.accentColor
    }

    static func dropIndicator(for appearance: WorkspaceLayoutConfiguration.Appearance) -> Color {
        _ = appearance
        return dropIndicator
    }

    static var focusRing: Color {
        Color.accentColor.opacity(0.5)
    }

    static var dirtyIndicator: Color {
        Color(nsColor: .labelColor).opacity(0.6)
    }

    static func dirtyIndicator(for appearance: WorkspaceLayoutConfiguration.Appearance) -> Color {
        guard chromeBackgroundColor(for: appearance) != nil else { return dirtyIndicator }
        return activeText(for: appearance).opacity(0.72)
    }

    private static func precompositedPaneBackground(
        for appearance: WorkspaceLayoutConfiguration.Appearance,
        focused: Bool
    ) -> NSColor {
        let chrome = nsColorPaneBackground(for: appearance)
        let windowBackground = NSColor.windowBackgroundColor
        guard let foreground = chrome.usingColorSpace(.sRGB),
              let background = windowBackground.usingColorSpace(.sRGB) else {
            return chrome.withAlphaComponent(1.0)
        }
        let alpha = focused ? foreground.alphaComponent : foreground.alphaComponent * 0.95
        let oneMinusAlpha = 1.0 - alpha
        let red = foreground.redComponent * alpha + background.redComponent * oneMinusAlpha
        let green = foreground.greenComponent * alpha + background.greenComponent * oneMinusAlpha
        let blue = foreground.blueComponent * alpha + background.blueComponent * oneMinusAlpha
        return NSColor(red: red, green: green, blue: blue, alpha: 1.0)
    }

    static var notificationBadge: Color {
        Color(nsColor: .systemBlue)
    }

    static func notificationBadge(for appearance: WorkspaceLayoutConfiguration.Appearance) -> Color {
        _ = appearance
        return notificationBadge
    }

    // MARK: - Shadows

    static var tabShadow: Color {
        Color.black.opacity(0.08)
    }
}

extension NSColor {
    static let workspaceSplitHexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    convenience init?(workspaceSplitHex value: String) {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        guard hex.unicodeScalars.allSatisfy({ Self.workspaceSplitHexDigits.contains($0) }) else { return nil }
        guard let rgba = UInt64(hex, radix: 16) else { return nil }
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if hex.count == 8 {
            red = CGFloat((rgba & 0xFF000000) >> 24) / 255.0
            green = CGFloat((rgba & 0x00FF0000) >> 16) / 255.0
            blue = CGFloat((rgba & 0x0000FF00) >> 8) / 255.0
            alpha = CGFloat(rgba & 0x000000FF) / 255.0
        } else {
            red = CGFloat((rgba & 0xFF0000) >> 16) / 255.0
            green = CGFloat((rgba & 0x00FF00) >> 8) / 255.0
            blue = CGFloat(rgba & 0x0000FF) / 255.0
            alpha = 1.0
        }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    var isWorkspaceLayoutLightColor: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let color = usingColorSpace(.sRGB) ?? self
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return luminance > 0.5
    }

    func workspaceSplitLighten(by amount: CGFloat) -> NSColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let color = usingColorSpace(.sRGB) ?? self
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return NSColor(
            red: min(1.0, red + amount),
            green: min(1.0, green + amount),
            blue: min(1.0, blue + amount),
            alpha: alpha
        )
    }

    func workspaceSplitDarken(by amount: CGFloat) -> NSColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let color = usingColorSpace(.sRGB) ?? self
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return NSColor(
            red: max(0.0, red - amount),
            green: max(0.0, green - amount),
            blue: max(0.0, blue - amount),
            alpha: alpha
        )
    }
}
