import AppKit
import Foundation
import SwiftUI

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
    let clampedOpacity = max(0, min(opacity, 1))
    return NSColor.white.withAlphaComponent(clampedOpacity)
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
