import AppKit
import CmuxFoundation
import SwiftUI

/// The resolved color shared by pane flashes and unread notification rings.
///
/// A configured color paints both. Without one, both signals use the existing
/// cmux accent, preserving the established blue default.
///
/// The setting store remains the only owner of the configured string. This
/// value validates one immutable snapshot before it reaches a renderer, so
/// AppKit layers and SwiftUI canvases never read ambient defaults or parse the
/// setting in their drawing loops.
struct WorkspaceAttentionColor: Hashable, Sendable {
    private let rgb: UInt32?
    /// The resolved cmux accent used when no valid color is configured.
    private let accent: CmuxAccentColor
    private let themeForegroundHex: String?
    private let useThemeForeground: Bool
    init(
        configuredHex: String?,
        accent: CmuxAccentColor = CmuxAccentColor(),
        themeForeground: NSColor? = nil,
        useThemeForeground: Bool = false
    ) {
        self.rgb = Self.strictRGB(configuredHex)
        self.accent = accent
        self.themeForegroundHex = themeForeground?.hexString()
        self.useThemeForeground = useThemeForeground
    }

    var nsColor: NSColor {
        guard let rgb else {
            return WorkspaceAttentionCoordinator.notificationRingStyle.accent.strokeColor(accent: accent)
        }
        return Self.color(rgb: rgb, alpha: 1)
    }

    /// The pane flash keeps the configured color or the existing cmux accent.
    var flashNSColor: NSColor {
        guard rgb == nil, useThemeForeground,
              let themeForegroundHex,
              let themeForeground = NSColor(hex: themeForegroundHex) else { return nsColor }
        return themeForeground
    }

    private static func color(rgb: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static func strictRGB(_ raw: String?) -> UInt32? {
        guard let raw else { return nil }
        let bytes = raw.utf8
        guard bytes.count == 7,
              bytes.first == 0x23,
              bytes.dropFirst().allSatisfy(isASCIIHexDigit) else { return nil }
        return UInt32(raw.dropFirst(), radix: 16)
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30 ... 0x39, 0x41 ... 0x46, 0x61 ... 0x66:
            return true
        default:
            return false
        }
    }
}

extension EnvironmentValues {
    @Entry var workspaceAttentionColor = WorkspaceAttentionColor(configuredHex: nil)
}
