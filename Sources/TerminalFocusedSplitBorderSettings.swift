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
struct TerminalFocusedSplitBorderSettings: Sendable {
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

    init() {}

    /// Whether the border is enabled, defaulting to ``defaultEnabled`` when the
    /// key has never been written.
    func isEnabled(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: Self.enabledKey) != nil else { return Self.defaultEnabled }
        return defaults.bool(forKey: Self.enabledKey)
    }

    /// The normalized `#RRGGBB` override, or `nil` when no valid override is set
    /// (in which case callers should fall back to the accent color).
    func resolvedColorHex(defaults: UserDefaults) -> String? {
        guard let raw = defaults.string(forKey: Self.colorHexKey) else { return nil }
        return WorkspaceTabColorSettings.normalizedHex(raw)
    }

    /// The resolved border color: the `#RRGGBB` override when valid, otherwise
    /// the system accent color.
    func resolvedColor(defaults: UserDefaults) -> NSColor {
        resolvedColor(colorHex: defaults.string(forKey: Self.colorHexKey))
    }

    /// Resolves a stored hex string into a border color, falling back to the
    /// system accent color when the value is missing or invalid. Factored out
    /// so the rendering layer can resolve a `@AppStorage`-read string directly.
    func resolvedColor(colorHex: String?) -> NSColor {
        if let colorHex,
           let normalized = WorkspaceTabColorSettings.normalizedHex(colorHex),
           let color = NSColor(hex: normalized) {
            return color
        }
        return cmuxAccentNSColor()
    }

    /// The resolved border width clamped to ``minimumWidth``...``maximumWidth``.
    func resolvedWidth(defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: Self.widthKey) != nil else { return Self.defaultWidth }
        return sanitizedWidth(defaults.double(forKey: Self.widthKey))
    }

    /// Clamps a width to the supported range, falling back to ``defaultWidth``
    /// for non-finite input.
    func sanitizedWidth(_ raw: Double) -> Double {
        guard raw.isFinite else { return Self.defaultWidth }
        return min(Self.maximumWidth, max(Self.minimumWidth, raw))
    }
}
