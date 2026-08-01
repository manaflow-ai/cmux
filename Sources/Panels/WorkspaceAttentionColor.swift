import AppKit
import CmuxFoundation

/// The resolved color shared by pane flashes and unread notification rings.
///
/// The setting store remains the only owner of the configured string. This
/// value validates one immutable snapshot before it reaches a renderer, so
/// AppKit layers and SwiftUI canvases never read ambient defaults or parse the
/// setting in their drawing loops.
struct WorkspaceAttentionColor: Equatable, Sendable {
    private let configuredHex: String?

    init(configuredHex: String?) {
        self.configuredHex = Self.normalizedStrictHex(configuredHex)
    }

    var nsColor: NSColor {
        guard let configuredHex, let color = NSColor(hex: configuredHex) else {
            return .systemBlue
        }
        return color
    }

    private static func normalizedStrictHex(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let bytes = raw.utf8
        guard bytes.count == 7,
              bytes.first == 0x23,
              bytes.dropFirst().allSatisfy(isASCIIHexDigit) else { return nil }
        return raw.uppercased()
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
