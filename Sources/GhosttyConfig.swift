import Foundation
import AppKit

struct GhosttyConfig {
    enum ColorSchemePreference: Hashable {
        case light
        case dark
    }

    // Native fallback for fresh installs when the user hasn't chosen terminal colors yet.
    static let cmuxDefaultLightThemeName = "Apple System Colors Light"
    static let cmuxDefaultDarkThemeName = "Apple System Colors"

    static let defaultSidebarFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.defaultSidebarFontSize)
    static let minSidebarFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.minSidebarFontSize)
    static let maxSidebarFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.maxSidebarFontSize)
    static let defaultSurfaceTabBarFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.defaultSurfaceTabBarFontSize)
    static let minSurfaceTabBarFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.minSurfaceTabBarFontSize)
    static let maxSurfaceTabBarFontSize = CGFloat(CmuxGhosttyConfigSettingEditor.maxSurfaceTabBarFontSize)

    var fontFamily: String = "Menlo"
    var fontSize: CGFloat = 12
    var surfaceTabBarFontSize: CGFloat = Self.defaultSurfaceTabBarFontSize
    var sidebarFontSize: CGFloat = Self.defaultSidebarFontSize
    var theme: String?
    var workingDirectory: String?
    // Ghostty measures scrollback-limit in bytes, not lines.
    var scrollbackLimit: Int = 10_000_000
    var unfocusedSplitOpacity: Double = 0.7
    var unfocusedSplitFill: NSColor?
    var splitDividerColor: NSColor?

    // Colors (from theme or config)
    var backgroundColor: NSColor = NSColor(hex: "#272822")!
    var hasBackgroundColorDirective = false
    var hasParsedBackgroundColor = false
    var backgroundOpacity: Double = 1.0
    var hasBackgroundOpacityDirective = false
    var hasParsedBackgroundOpacity = false
    var backgroundBlur: GhosttyBackgroundBlur = .disabled
    var hasBackgroundBlurDirective = false
    var hasParsedBackgroundBlur = false
    var foregroundColor: NSColor = NSColor(hex: "#fdfff1")!
    var hasForegroundColorDirective = false
    var hasParsedForegroundColor = false
    var cursorColor: NSColor = NSColor(hex: "#c0c1b5")!
    var hasCursorColorDirective = false
    var hasParsedCursorColor = false
    var cursorTextColor: NSColor = NSColor(hex: "#8d8e82")!
    var hasCursorTextColorDirective = false
    var hasParsedCursorTextColor = false
    var selectionBackground: NSColor = NSColor(hex: "#57584f")!
    var hasSelectionBackgroundDirective = false
    var hasParsedSelectionBackground = false
    var selectionForeground: NSColor = NSColor(hex: "#fdfff1")!
    var hasSelectionForegroundDirective = false
    var hasParsedSelectionForeground = false

    // Sidebar appearance
    var rawSidebarBackground: String?
    var sidebarBackground: NSColor?
    var sidebarBackgroundLight: NSColor?
    var sidebarBackgroundDark: NSColor?
    var sidebarTintOpacity: Double?

    // Palette colors (0-15)
    var palette: [Int: NSColor] = [:]

    var unfocusedSplitOverlayOpacity: Double {
        let clamped = min(1.0, max(0.15, unfocusedSplitOpacity))
        return min(1.0, max(0.0, 1.0 - clamped))
    }

    var unfocusedSplitOverlayFill: NSColor {
        unfocusedSplitFill ?? backgroundColor
    }

    var resolvedSplitDividerColor: NSColor {
        if let splitDividerColor {
            return splitDividerColor
        }

        let isLightBackground = backgroundColor.isLightColor
        return backgroundColor.darken(by: isLightBackground ? 0.08 : 0.4)
    }

}

