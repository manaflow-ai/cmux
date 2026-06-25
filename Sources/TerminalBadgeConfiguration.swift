import AppKit
import CmuxSettings
import CmuxSettingsUI
import Foundation

/// An immutable snapshot of the `badge.*` settings, read from the cmux JSON
/// config store, that drives the terminal badge overlay's appearance.
///
/// The snapshot is read synchronously from a ``CmuxSettings/JSONConfigStore``
/// (via its `snapshotValue` seam) so the overlay can apply it on the main actor
/// without awaiting. The overlay also observes the store's change streams and
/// rebuilds a fresh snapshot when the config file changes.
struct TerminalBadgeConfiguration: Equatable {
    /// Whether the badge is shown at all.
    let enabled: Bool
    /// The raw, unrendered text template (see ``TerminalBadgeTemplate``).
    let template: TerminalBadgeTemplate
    /// Which corner (or center) the badge anchors to.
    let position: BadgePosition
    /// Badge opacity in `0...1`.
    let opacity: Double
    /// Badge font size in points, already clamped to the catalog's range.
    let fontSize: Double
    /// Resolved badge text color, or `nil` to follow the terminal label color.
    let color: NSColor?

    /// The default snapshot used before a runtime is available: disabled, with
    /// catalog defaults for everything else.
    static let disabled = TerminalBadgeConfiguration(
        enabled: false,
        template: TerminalBadgeTemplate(rawValue: TerminalBadgeTemplate.defaultRawValue),
        position: .topTrailing,
        opacity: BadgeCatalogSection.opacityDefault,
        fontSize: BadgeCatalogSection.fontSizeDefault,
        color: nil
    )

    /// Reads the current snapshot synchronously from the runtime's JSON store.
    ///
    /// Falls back to ``disabled`` when no runtime is available (e.g. during very
    /// early startup), so callers never need to special-case a missing runtime.
    ///
    /// - Parameter runtime: The app's settings runtime, or `nil`.
    /// - Returns: The current badge configuration snapshot.
    static func snapshot(runtime: SettingsRuntime?) -> TerminalBadgeConfiguration {
        guard let runtime else { return .disabled }
        let store = runtime.jsonStore
        let catalog = runtime.catalog
        let rawOpacity = store.snapshotValue(for: catalog.badge.opacity)
        let rawFontSize = store.snapshotValue(for: catalog.badge.fontSize)
        return TerminalBadgeConfiguration(
            enabled: store.snapshotValue(for: catalog.badge.enabled),
            template: TerminalBadgeTemplate(rawValue: store.snapshotValue(for: catalog.badge.template)),
            position: store.snapshotValue(for: catalog.badge.position),
            opacity: Self.clampedOpacity(rawOpacity),
            fontSize: Self.clampedFontSize(rawFontSize),
            color: Self.parseColor(store.snapshotValue(for: catalog.badge.color))
        )
    }

    /// Clamps an opacity to `0...1`, mapping a non-finite value to the default.
    static func clampedOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return BadgeCatalogSection.opacityDefault }
        return min(max(value, 0), 1)
    }

    /// Clamps a font size to the catalog's allowed range, mapping a non-finite
    /// value to the default.
    static func clampedFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return BadgeCatalogSection.fontSizeDefault }
        return min(max(value, BadgeCatalogSection.fontSizeMinimum), BadgeCatalogSection.fontSizeMaximum)
    }

    /// Parses a badge color string into an `NSColor`, or `nil` when empty or
    /// malformed (so the overlay falls back to the terminal label color).
    ///
    /// Accepts either a `#RRGGBB` hex string or a SwiftUI system color name
    /// (`red`, `blue`, `mint`, …); resolution is delegated to ``BadgeColor``.
    static func parseColor(_ raw: String) -> NSColor? {
        guard let badgeColor = BadgeColor(parsing: raw) else { return nil }
        return NSColor(
            srgbRed: CGFloat(badgeColor.red),
            green: CGFloat(badgeColor.green),
            blue: CGFloat(badgeColor.blue),
            alpha: 1
        )
    }
}
