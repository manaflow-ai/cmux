import AppKit
import SwiftUI

/// The resolved color shared by pane flashes and unread notification rings.
///
/// The setting store remains the only owner of the configured string. This
/// value validates one immutable snapshot before it reaches a renderer, so
/// AppKit layers and SwiftUI canvases never read ambient defaults or parse the
/// setting in their drawing loops.
struct WorkspaceAttentionColor: Equatable, Sendable {
    private let rgb: UInt32?

    init(configuredHex: String?) {
        self.rgb = Self.strictRGB(configuredHex)
    }

    var nsColor: NSColor {
        guard let rgb else {
            return WorkspaceAttentionCoordinator.notificationRingStyle.accent.strokeColor
        }
        return NSColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
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
