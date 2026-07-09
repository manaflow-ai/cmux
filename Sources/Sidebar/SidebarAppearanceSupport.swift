import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSidebarUI
import Foundation
import SwiftUI
import CmuxSettings
import CmuxWorkspaces

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

// MARK: - Transitional forwarders into CmuxSidebarUI color math
//
// The pure sidebar/titlebar color + contrast math now lives in
// `CmuxSidebarUI` as static members on `SidebarContrastMath` /
// `SidebarSelectionColors`. These one-line free-function forwarders preserve
// the existing app-target call sites unchanged while the callers migrate to
// the package types directly.

func coloredCircleImage(color: NSColor) -> NSImage {
    SidebarSelectionColors.coloredCircleImage(color: color)
}

func sidebarActiveForegroundNSColor(
    opacity: CGFloat,
    appAppearance: NSAppearance? = NSApp?.effectiveAppearance
) -> NSColor {
    SidebarSelectionColors.sidebarActiveForegroundNSColor(
        opacity: opacity,
        appAppearance: appAppearance
    )
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
    SidebarSelectionColors.accentNSColor(for: colorScheme)
}

func cmuxAccentNSColor(for appAppearance: NSAppearance?) -> NSColor {
    SidebarSelectionColors.accentNSColor(for: appAppearance)
}

func cmuxAccentNSColor() -> NSColor {
    SidebarSelectionColors.accentNSColor()
}

func cmuxAccentColor() -> Color {
    SidebarSelectionColors.accentColor()
}

func cmuxReadableColorScheme(for backgroundColor: NSColor) -> ColorScheme {
    SidebarContrastMath.readableColorScheme(for: backgroundColor)
}

func cmuxReadableForegroundNSColor(on backgroundColor: NSColor, opacity: CGFloat) -> NSColor {
    SidebarContrastMath.readableForegroundNSColor(on: backgroundColor, opacity: opacity)
}

func cmuxReadableForegroundNSColor(
    preferred preferredColor: NSColor,
    on backgroundColor: NSColor,
    minimumContrast: CGFloat = 4.5
) -> NSColor {
    SidebarContrastMath.readableForegroundNSColor(
        preferred: preferredColor,
        on: backgroundColor,
        minimumContrast: minimumContrast
    )
}

func cmuxCompositedNSColor(_ foreground: NSColor, over background: NSColor) -> NSColor {
    SidebarContrastMath.compositedNSColor(foreground, over: background)
}

func cmuxContrastRatio(foreground: NSColor, background: NSColor) -> CGFloat {
    SidebarContrastMath.contrastRatio(foreground: foreground, background: background)
}

func sidebarSelectedWorkspaceBackgroundNSColor(
    for colorScheme: ColorScheme,
    sidebarSelectionColorHex: String? = UserDefaults.standard.string(forKey: "sidebarSelectionColorHex")
) -> NSColor {
    SidebarSelectionColors.sidebarSelectedWorkspaceBackgroundNSColor(
        for: colorScheme,
        sidebarSelectionColorHex: sidebarSelectionColorHex
    )
}

func sidebarSelectedWorkspaceForegroundNSColor(opacity: CGFloat) -> NSColor {
    SidebarSelectionColors.sidebarSelectedWorkspaceForegroundNSColor(opacity: opacity)
}

func sidebarSelectedWorkspaceForegroundNSColor(
    on backgroundColor: NSColor,
    opacity: CGFloat
) -> NSColor {
    SidebarSelectionColors.sidebarSelectedWorkspaceForegroundNSColor(
        on: backgroundColor,
        opacity: opacity
    )
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

struct SidebarWorkspaceRowBackgroundStyle {
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
    return WorkspaceTabColorSettings().displayNSColor(
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
        WorkspaceTabColorSettings().displayNSColor(
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
