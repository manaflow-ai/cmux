import AppKit
import Foundation
import SwiftUI

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

/// Per-state colors for the sidebar agent lifecycle indicators (the status
/// pills cmux writes for Claude Code, Codex, and every other detected agent).
///
/// The agent lifecycle detection — both the in-app `FeedCoordinator` and the
/// `cmux` CLI hooks that drive `set_status` over the socket — writes each
/// lifecycle pill with a fixed `(color, icon)` signature. This type recolors
/// those built-in pills at render time from the user's `sidebar.stateIndicatorColors`
/// override, so the same color knob applies to every agent and there is no race
/// with the detection writes (the override wins whenever the snapshot is built,
/// regardless of which write landed last). When an override is unset the pill
/// keeps its built-in color, so default behavior is unchanged.
///
/// Recoloring keys off the built-in signature, not the agent key, so a pill the
/// user customized with `cmux set-status --color` (any non-default color) is
/// never touched.
enum SidebarAgentStateIndicatorColors {
    /// UserDefaults keys holding the resolved per-state override hex (or nil).
    static let runningColorKey = "sidebarStateIndicatorRunningColorHex"
    static let needsInputColorKey = "sidebarStateIndicatorNeedsInputColorHex"
    static let idleColorKey = "sidebarStateIndicatorIdleColorHex"

    /// Built-in `(color, icon)` signatures written by the lifecycle detection.
    static let defaultRunningColorHex = "#4C8DFF"
    static let defaultNeedsInputColorHex = "#4C8DFF"
    static let defaultIdleColorHex = "#8E8E93"
    static let runningIcon = "bolt.fill"
    static let needsInputIcon = "bell.fill"
    static let idleIcon = "pause.circle.fill"

    enum State: Equatable {
        case running
        case needsInput
        case idle
    }

    /// Identifies a built-in agent lifecycle indicator from the `(color, icon)`
    /// signature the detection writes. Returns nil for anything else — including
    /// user `cmux set-status --color` overrides — so custom colors are preserved.
    static func builtInState(colorHex: String?, icon: String?) -> State? {
        guard let colorHex else { return nil }
        let color = colorHex.uppercased()
        let rawIcon = icon ?? ""
        let normalizedIcon = rawIcon.hasPrefix("sf:") ? String(rawIcon.dropFirst(3)) : rawIcon
        if color == defaultRunningColorHex, normalizedIcon == runningIcon { return .running }
        if color == defaultNeedsInputColorHex, normalizedIcon == needsInputIcon { return .needsInput }
        if color == defaultIdleColorHex, normalizedIcon == idleIcon { return .idle }
        return nil
    }

    /// Resolves the effective color hex for a status entry, substituting the
    /// configured override for its lifecycle state when the entry is a built-in
    /// indicator and an override is set. Falls back to the entry's own color.
    static func resolvedColorHex(
        entryColorHex: String?,
        entryIcon: String?,
        runningOverrideHex: String?,
        needsInputOverrideHex: String?,
        idleOverrideHex: String?
    ) -> String? {
        guard let state = builtInState(colorHex: entryColorHex, icon: entryIcon) else {
            return entryColorHex
        }
        switch state {
        case .running:
            return runningOverrideHex ?? entryColorHex
        case .needsInput:
            return needsInputOverrideHex ?? entryColorHex
        case .idle:
            return idleOverrideHex ?? entryColorHex
        }
    }

    /// Returns `entries` with built-in lifecycle pills recolored from the
    /// configured overrides. Identity-preserving when no override is set.
    static func recolored(
        _ entries: [SidebarStatusEntry],
        runningOverrideHex: String?,
        needsInputOverrideHex: String?,
        idleOverrideHex: String?
    ) -> [SidebarStatusEntry] {
        if runningOverrideHex == nil, needsInputOverrideHex == nil, idleOverrideHex == nil {
            return entries
        }
        return entries.map { entry in
            let resolved = resolvedColorHex(
                entryColorHex: entry.color,
                entryIcon: entry.icon,
                runningOverrideHex: runningOverrideHex,
                needsInputOverrideHex: needsInputOverrideHex,
                idleOverrideHex: idleOverrideHex
            )
            guard resolved != entry.color else { return entry }
            return SidebarStatusEntry(
                key: entry.key,
                value: entry.value,
                icon: entry.icon,
                color: resolved,
                url: entry.url,
                priority: entry.priority,
                format: entry.format,
                timestamp: entry.timestamp
            )
        }
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

func titlebarControlForegroundNSColor(
    opacity: CGFloat,
    appearance: WindowAppearanceSnapshot = .currentFromUserDefaults()
) -> NSColor {
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

struct SidebarWorkspaceRowBackgroundStyle {
    let color: NSColor?
    let opacity: Double

    static let clear = Self(color: nil, opacity: 0)
}

func sidebarWorkspaceRowExplicitRailNSColor(
    activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle,
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
    activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle,
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
