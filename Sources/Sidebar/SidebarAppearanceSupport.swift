import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import Foundation
import SwiftUI
import CmuxSettings

enum SidebarMatchTerminalBackgroundSettings {
    static let userDefaultsKey = "sidebarMatchTerminalBackground"
    static let legacyAppliedSettingsFileDefaultKey = "cmux.settingsFile.sidebarMatchTerminalBackground.appliedDefault.v1"
}

enum SidebarTabItemFontScale {
    static func scale(for sidebarFontSize: CGFloat) -> CGFloat {
        GhosttyConfig.clampedSidebarFontSize(sidebarFontSize)
            / GhosttyConfig.defaultSidebarFontSize
    }
}

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8)  & 0xFF) / 255.0,
            blue:  Double( value        & 0xFF) / 255.0
        )
    }
}

func coloredCircleImage(color: NSColor) -> NSImage {
    let size = NSSize(width: 14, height: 14)
    let image = NSImage(size: size, flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    image.isTemplate = false
    return image
}

func sidebarActiveForegroundNSColor(
    opacity: CGFloat,
    appAppearance: NSAppearance? = NSApp?.effectiveAppearance
) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    let bestMatch = appAppearance?.bestMatch(from: [.darkAqua, .aqua])
    let baseColor: NSColor = (bestMatch == .darkAqua) ? .white : .black
    return baseColor.withAlphaComponent(clampedOpacity)
}

func titlebarControlForegroundNSColor(opacity: CGFloat) -> NSColor {
    let app = GhosttyApp.shared
    let bestMatch = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
    let colorScheme: ColorScheme = bestMatch == .darkAqua ? .dark : .light
    let appearance = WindowAppearanceResolver(
        terminalAppearance: WindowTerminalAppearanceSnapshot(
            backgroundColor: app.defaultBackgroundColor,
            backgroundOpacity: app.defaultBackgroundOpacity,
            backgroundBlur: app.defaultBackgroundBlur,
            usesHostLayerBackground: app.usesHostLayerBackground
        )
    ).currentFromUserDefaults(defaults: .standard, colorScheme: colorScheme)
    return titlebarControlForegroundNSColor(
        opacity: opacity,
        appearance: appearance
    )
}

func titlebarControlForegroundNSColor(opacity: CGFloat, appearance: WindowAppearanceSnapshot) -> NSColor {
    cmuxReadableForegroundNSColor(
        on: appearance.compositedTerminalBackgroundColor,
        opacity: opacity
    )
}

func cmuxAccentNSColor(for colorScheme: ColorScheme) -> NSColor {
    switch colorScheme {
    case .dark:
        return NSColor(
            srgbRed: 0,
            green: 145.0 / 255.0,
            blue: 1.0,
            alpha: 1.0
        )
    default:
        return NSColor(
            srgbRed: 0,
            green: 136.0 / 255.0,
            blue: 1.0,
            alpha: 1.0
        )
    }
}

func cmuxAccentNSColor(for appAppearance: NSAppearance?) -> NSColor {
    let bestMatch = appAppearance?.bestMatch(from: [.darkAqua, .aqua])
    let scheme: ColorScheme = (bestMatch == .darkAqua) ? .dark : .light
    return cmuxAccentNSColor(for: scheme)
}

func cmuxAccentNSColor() -> NSColor {
    NSColor(name: nil) { appearance in
        cmuxAccentNSColor(for: appearance)
    }
}

func cmuxAccentColor() -> Color {
    Color(nsColor: cmuxAccentNSColor())
}

func cmuxReadableColorScheme(for backgroundColor: NSColor) -> ColorScheme {
    let backgroundLuminance = cmuxRelativeLuminance(backgroundColor)
    let whiteContrast = cmuxContrastRatio(backgroundLuminance, 1.0)
    let blackContrast = cmuxContrastRatio(backgroundLuminance, 0.0)
    return whiteContrast >= blackContrast ? .dark : .light
}

func cmuxReadableForegroundNSColor(on backgroundColor: NSColor, opacity: CGFloat) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    return cmuxReadableForegroundBaseColor(on: backgroundColor)
        .withAlphaComponent(clampedOpacity)
}

func cmuxReadableForegroundNSColor(
    preferred preferredColor: NSColor,
    on backgroundColor: NSColor,
    minimumContrast: CGFloat = 4.5
) -> NSColor {
    let foregroundForComparison = preferredColor.alphaComponent < 1
        ? cmuxCompositedNSColor(preferredColor, over: backgroundColor)
        : preferredColor
    guard cmuxContrastRatio(foreground: foregroundForComparison, background: backgroundColor) < minimumContrast else {
        return preferredColor
    }
    return cmuxReadableForegroundNSColor(on: backgroundColor, opacity: preferredColor.alphaComponent)
}

func cmuxCompositedNSColor(_ foreground: NSColor, over background: NSColor) -> NSColor {
    let fg = foreground.usingColorSpace(.sRGB) ?? foreground
    let bg = background.usingColorSpace(.sRGB) ?? background
    var foregroundRed: CGFloat = 0
    var foregroundGreen: CGFloat = 0
    var foregroundBlue: CGFloat = 0
    var foregroundAlpha: CGFloat = 0
    var backgroundRed: CGFloat = 0
    var backgroundGreen: CGFloat = 0
    var backgroundBlue: CGFloat = 0
    var backgroundAlpha: CGFloat = 0
    fg.getRed(&foregroundRed, green: &foregroundGreen, blue: &foregroundBlue, alpha: &foregroundAlpha)
    bg.getRed(&backgroundRed, green: &backgroundGreen, blue: &backgroundBlue, alpha: &backgroundAlpha)
    _ = backgroundAlpha

    let alpha = max(0, min(foregroundAlpha, 1))
    return NSColor(
        srgbRed: foregroundRed * alpha + backgroundRed * (1 - alpha),
        green: foregroundGreen * alpha + backgroundGreen * (1 - alpha),
        blue: foregroundBlue * alpha + backgroundBlue * (1 - alpha),
        alpha: 1
    )
}

func cmuxContrastRatio(foreground: NSColor, background: NSColor) -> CGFloat {
    cmuxContrastRatio(
        cmuxRelativeLuminance(foreground),
        cmuxRelativeLuminance(background)
    )
}

/// Preserves the preferred accent whenever it is readable, otherwise makes the
/// smallest 8-bit sRGB move toward white or black that reaches the requested
/// contrast. This keeps cmux blue recognizable across arbitrary terminal
/// themes instead of replacing it with a generic foreground color.
func cmuxContrastAdjustedAccentNSColor(
    _ preferredColor: NSColor,
    on backgroundColor: NSColor,
    minimumContrast: CGFloat = 4.5
) -> NSColor {
    let preferred = CmuxRGBBytes(color: preferredColor).color
    let background = CmuxRGBBytes(color: backgroundColor).color
    guard cmuxContrastRatio(foreground: preferred, background: background) < minimumContrast else {
        return preferred
    }

    let candidates = [0, 255].compactMap { targetComponent in
        cmuxContrastAdjustmentCandidate(
            preferred: CmuxRGBBytes(color: preferred),
            background: background,
            targetComponent: targetComponent,
            minimumContrast: minimumContrast
        )
    }
    if let candidate = candidates.min(by: {
        if $0.step == $1.step {
            return $0.contrast > $1.contrast
        }
        return $0.step < $1.step
    }) {
        return candidate.color
    }

    let black = NSColor.black
    let white = NSColor.white
    return cmuxContrastRatio(foreground: white, background: background)
        >= cmuxContrastRatio(foreground: black, background: background)
        ? white
        : black
}

private struct CmuxRGBBytes {
    let red: Int
    let green: Int
    let blue: Int

    init(color: NSColor) {
        let value = UInt64(color.hexString().dropFirst(), radix: 16) ?? 0
        red = Int((value >> 16) & 0xFF)
        green = Int((value >> 8) & 0xFF)
        blue = Int(value & 0xFF)
    }

    init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var color: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    func mixed(toward targetComponent: Int, step: Int) -> CmuxRGBBytes {
        func mix(_ component: Int) -> Int {
            (component * (255 - step) + targetComponent * step) / 255
        }
        return CmuxRGBBytes(
            red: mix(red),
            green: mix(green),
            blue: mix(blue)
        )
    }
}

private struct CmuxContrastAdjustmentCandidate {
    let color: NSColor
    let step: Int
    let contrast: CGFloat
}

private func cmuxContrastAdjustmentCandidate(
    preferred: CmuxRGBBytes,
    background: NSColor,
    targetComponent: Int,
    minimumContrast: CGFloat
) -> CmuxContrastAdjustmentCandidate? {
    for step in 1...255 {
        let color = preferred.mixed(toward: targetComponent, step: step).color
        let contrast = cmuxContrastRatio(foreground: color, background: background)
        if contrast >= minimumContrast {
            return CmuxContrastAdjustmentCandidate(
                color: color,
                step: step,
                contrast: contrast
            )
        }
    }
    return nil
}

private func cmuxReadableForegroundBaseColor(on backgroundColor: NSColor) -> NSColor {
    cmuxReadableColorScheme(for: backgroundColor) == .dark ? .white : .black
}

private func cmuxRelativeLuminance(_ color: NSColor) -> CGFloat {
    let srgb = color.usingColorSpace(.sRGB) ?? color
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    _ = alpha

    func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928
            ? component / 12.92
            : CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
    }

    return 0.2126 * linearized(red)
        + 0.7152 * linearized(green)
        + 0.0722 * linearized(blue)
}

private func cmuxContrastRatio(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
    let lighter = max(lhs, rhs)
    let darker = min(lhs, rhs)
    return (lighter + 0.05) / (darker + 0.05)
}

struct SidebarRemoteErrorCopyEntry: Equatable {
    let workspaceTitle: String
    let target: String
    let detail: String
}

enum SidebarRemoteErrorCopySupport {
    static func menuLabel(for entries: [SidebarRemoteErrorCopyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1 {
            return String(localized: "contextMenu.copyError", defaultValue: "Copy Error")
        }
        return String(localized: "contextMenu.copyErrors", defaultValue: "Copy Errors")
    }

    static func clipboardText(for entries: [SidebarRemoteErrorCopyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1, let entry = entries.first {
            return String.localizedStringWithFormat(
                String(localized: "clipboard.sshError.single", defaultValue: "SSH error (%@): %@"),
                entry.target,
                entry.detail
            )
        }

        return entries.enumerated().map { index, entry in
            String.localizedStringWithFormat(
                String(localized: "clipboard.sshError.item", defaultValue: "%lld. %@ (%@): %@"),
                Int64(index + 1),
                entry.workspaceTitle,
                entry.target,
                entry.detail
            )
        }.joined(separator: "\n")
    }
}

func sidebarSelectedWorkspaceBackgroundNSColor(
    for colorScheme: ColorScheme,
    sidebarSelectionColorHex: String? = UserDefaults.standard.string(forKey: "sidebarSelectionColorHex")
) -> NSColor {
    if let hex = sidebarSelectionColorHex,
       let parsed = NSColor(hex: hex) {
        return parsed
    }
    return cmuxAccentNSColor(for: colorScheme)
}

func sidebarSelectedWorkspaceForegroundNSColor(opacity: CGFloat) -> NSColor {
    sidebarSelectedWorkspaceForegroundNSColor(
        on: sidebarSelectedWorkspaceBackgroundNSColor(for: .dark),
        opacity: opacity
    )
}

func sidebarSelectedWorkspaceForegroundNSColor(
    on backgroundColor: NSColor,
    opacity: CGFloat
) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    let whiteContrast = cmuxContrastRatio(foreground: .white, background: backgroundColor)
    guard whiteContrast < 2.75 else {
        return NSColor.white.withAlphaComponent(clampedOpacity)
    }
    return cmuxReadableForegroundNSColor(on: backgroundColor, opacity: clampedOpacity)
}

struct SidebarWorkspaceRowBackgroundStyle: Equatable, Hashable {
    let color: NSColor?
    let opacity: Double

    static let clear = Self(color: nil, opacity: 0)
}

func sidebarWorkspaceRowExplicitRailNSColor(
    activeTabIndicatorStyle: WorkspaceIndicatorStyle,
    customColorHex: String?,
    colorScheme: ColorScheme
) -> NSColor? {
    guard activeTabIndicatorStyle == .leftRail,
          let customColorHex else {
        return nil
    }
    return WorkspaceTabColorSettings.displayNSColor(
        hex: customColorHex,
        colorScheme: colorScheme,
        forceBright: true
    )
}

func sidebarWorkspaceRowBackgroundStyle(
    activeTabIndicatorStyle: WorkspaceIndicatorStyle,
    isActive: Bool,
    isMultiSelected: Bool,
    customColorHex: String?,
    colorScheme: ColorScheme,
    sidebarSelectionColorHex: String?
) -> SidebarWorkspaceRowBackgroundStyle {
    let selectedBackground = sidebarSelectedWorkspaceBackgroundNSColor(
        for: colorScheme,
        sidebarSelectionColorHex: sidebarSelectionColorHex
    )
    let accentBackground = cmuxAccentNSColor(for: colorScheme)
    let customBackground = customColorHex.flatMap {
        WorkspaceTabColorSettings.displayNSColor(
            hex: $0,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        )
    }

    switch activeTabIndicatorStyle {
    case .leftRail:
        if isActive {
            return SidebarWorkspaceRowBackgroundStyle(
                color: selectedBackground,
                opacity: 1
            )
        }
        if isMultiSelected {
            return SidebarWorkspaceRowBackgroundStyle(color: accentBackground, opacity: 0.25)
        }
        return .clear

    case .solidFill:
        if isActive {
            return SidebarWorkspaceRowBackgroundStyle(
                color: selectedBackground,
                opacity: 1
            )
        }
        if let customBackground {
            return SidebarWorkspaceRowBackgroundStyle(
                color: customBackground,
                opacity: isMultiSelected ? 0.35 : 0.7
            )
        }
        if isMultiSelected {
            return SidebarWorkspaceRowBackgroundStyle(color: accentBackground, opacity: 0.25)
        }
        return .clear
    }
}
