import AppKit
import Foundation

/// Decoded `ui.paneDivider` block from a cmux config file.
///
/// Both fields are optional so a config can override just the color, just the
/// thickness, or both. Validation happens at decode time: `color` must be a
/// `#RRGGBB` or `#RRGGBBAA` hex string and `thickness` must be a finite,
/// non-negative number.
struct CmuxConfigPaneDivider: Codable, Sendable, Hashable {
    var color: String?
    var thickness: Double?

    private enum CodingKeys: String, CodingKey {
        case color
        case thickness
    }

    init(color: String? = nil, thickness: Double? = nil) {
        self.color = color
        self.thickness = thickness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let rawColor = try container.decodeIfPresent(String.self, forKey: .color) {
            let trimmed = rawColor.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                color = nil
            } else if NSColor(cmuxPaneDividerHex: trimmed) == nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .color,
                    in: container,
                    debugDescription: "paneDivider color must be a #RRGGBB or #RRGGBBAA hex string"
                )
            } else {
                color = trimmed
            }
        } else {
            color = nil
        }

        if let rawThickness = try container.decodeIfPresent(Double.self, forKey: .thickness) {
            guard rawThickness.isFinite, rawThickness >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .thickness,
                    in: container,
                    debugDescription: "paneDivider thickness must be a non-negative number"
                )
            }
            thickness = rawThickness
        } else {
            thickness = nil
        }
    }
}

/// A resolved cmux-config divider override, with the hex color parsed into an
/// `NSColor`. Either field may be `nil` (meaning "fall through to the next
/// configuration layer"). This is the value ``PaneDividerStyle/resolved(override:ghosttyDividerColor:)``
/// consumes from the cmux configuration layer.
struct CmuxPaneDividerOverride: Equatable {
    var color: NSColor?
    var thickness: CGFloat?

    /// The empty override: defer entirely to lower configuration layers.
    static let none = CmuxPaneDividerOverride()

    /// Build an override from a decoded config block, parsing the hex color.
    init(color: NSColor? = nil, thickness: CGFloat? = nil) {
        self.color = color
        self.thickness = thickness
    }

    init(config: CmuxConfigPaneDivider?) {
        guard let config else {
            self = .none
            return
        }
        color = config.color.flatMap { NSColor(cmuxPaneDividerHex: $0) }
        thickness = config.thickness.map { CGFloat($0) }
    }

    static func == (lhs: CmuxPaneDividerOverride, rhs: CmuxPaneDividerOverride) -> Bool {
        lhs.thickness == rhs.thickness
            && lhs.color?.hexString(includeAlpha: true) == rhs.color?.hexString(includeAlpha: true)
    }
}

extension Notification.Name {
    /// Posted on the main actor when the resolved cmux-config pane-divider
    /// override changes, so visible workspaces can re-apply chrome in place
    /// without an app restart.
    static let cmuxPaneDividerConfigDidChange = Notification.Name("cmuxPaneDividerConfigDidChange")
}

/// App-wide cache of the resolved cmux-config pane-divider override.
///
/// `CmuxConfigStore` is the authority: it merges the global and project-scoped
/// `ui.paneDivider` blocks and pushes the result here on every reload. The
/// workspace chrome code reads ``current`` when (re)building Bonsplit
/// appearance. It is a small piece of main-actor UI state, in the same spirit
/// as the surrounding `GhosttyApp.shared` chrome inputs.
@MainActor
final class PaneDividerConfigState {
    static let shared = PaneDividerConfigState()

    private(set) var current: CmuxPaneDividerOverride = .none

    private init() {}

    /// Replace the current override. Returns `true` when the value changed.
    @discardableResult
    func update(_ newValue: CmuxPaneDividerOverride) -> Bool {
        guard newValue != current else { return false }
        current = newValue
        return true
    }
}

extension NSColor {
    /// Parse a `#RRGGBB` or `#RRGGBBAA` hex string for pane-divider config.
    ///
    /// Unlike ``init(hex:)`` (6-digit only), this accepts an optional trailing
    /// alpha byte so a divider can be configured as translucent.
    convenience init?(cmuxPaneDividerHex hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(of: "#", with: "")

        var value: UInt64 = 0
        guard Scanner(string: sanitized).scanHexInt64(&value) else { return nil }

        let r, g, b, a: CGFloat
        switch sanitized.count {
        case 6:
            r = CGFloat((value & 0xFF0000) >> 16) / 255.0
            g = CGFloat((value & 0x00FF00) >> 8) / 255.0
            b = CGFloat(value & 0x0000FF) / 255.0
            a = 1.0
        case 8:
            r = CGFloat((value & 0xFF00_0000) >> 24) / 255.0
            g = CGFloat((value & 0x00FF_0000) >> 16) / 255.0
            b = CGFloat((value & 0x0000_FF00) >> 8) / 255.0
            a = CGFloat(value & 0x0000_00FF) / 255.0
        default:
            return nil
        }

        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
