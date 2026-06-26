import AppKit
import CmuxFoundation
import Foundation

/// User settings for the focused-split border: a configurable accent outline
/// drawn around the focused terminal pane while a workspace is split into
/// multiple panes. It complements the existing unfocused-split dimming
/// (Ghostty's `unfocused-split-opacity`) by positively marking which pane has
/// keyboard focus, so typing into the wrong split is harder.
///
/// The border is rendered in the AppKit portal layer inside
/// ``GhosttySurfaceScrollView`` (parallel to the inactive-overlay and unread
/// notification ring), because the portal-hosted terminal can sit above
/// SwiftUI overlays during split/workspace churn.
///
/// These `userDefaultsKey` strings are mirrored by the `terminal.*` keys in
/// `TerminalCatalogSection`; keep the two in sync.
enum TerminalFocusedSplitBorderSettings {
    /// Whether to draw the focused-split border at all.
    static let enabledKey = "terminalFocusedSplitBorderEnabled"
    /// Optional `#RRGGBB` override for the border color. Empty (the default)
    /// means follow the system accent color.
    static let colorHexKey = "terminalFocusedSplitBorderColorHex"
    /// Border stroke width, in points.
    static let widthKey = "terminalFocusedSplitBorderWidth"

    static let defaultEnabled = true
    /// Empty string resolves to the system accent color.
    static let defaultColorHex = ""
    static let defaultWidth: Double = 2.0
    static let minimumWidth: Double = 0.5
    static let maximumWidth: Double = 8.0

    /// Whether the border is enabled, defaulting to ``defaultEnabled`` when the
    /// key has never been written.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }

    /// The normalized `#RRGGBB` override, or `nil` when no valid override is set
    /// (in which case callers should fall back to the accent color).
    static func resolvedColorHex(defaults: UserDefaults = .standard) -> String? {
        guard let raw = defaults.string(forKey: colorHexKey) else { return nil }
        return WorkspaceTabColorSettings.normalizedHex(raw)
    }

    /// The resolved border color: the `#RRGGBB` override when valid, otherwise
    /// the system accent color.
    static func resolvedColor(defaults: UserDefaults = .standard) -> NSColor {
        resolvedColor(colorHex: defaults.string(forKey: colorHexKey))
    }

    /// Resolves a stored hex string into a border color, falling back to the
    /// system accent color when the value is missing or invalid. Factored out
    /// so the rendering layer can resolve a `@AppStorage`-read string directly.
    static func resolvedColor(colorHex: String?) -> NSColor {
        if let colorHex,
           let normalized = WorkspaceTabColorSettings.normalizedHex(colorHex),
           let color = NSColor(hex: normalized) {
            return color
        }
        return cmuxAccentNSColor()
    }

    /// The resolved border width clamped to ``minimumWidth``...``maximumWidth``.
    static func resolvedWidth(defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: widthKey) != nil else { return defaultWidth }
        return sanitizedWidth(defaults.double(forKey: widthKey))
    }

    /// Clamps a width to the supported range, falling back to ``defaultWidth``
    /// for non-finite input.
    static func sanitizedWidth(_ raw: Double) -> Double {
        guard raw.isFinite else { return defaultWidth }
        return min(maximumWidth, max(minimumWidth, raw))
    }
}
