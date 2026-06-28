import Foundation

/// Where the terminal badge watermark is anchored inside a terminal surface.
///
/// Stored under the catalog entry ``BadgeCatalogSection/position``
/// (`badge.position` in `~/.config/cmux/cmux.json`). The raw values are the
/// on-disk strings, so they must not be renamed without a migration. The
/// default is ``topTrailing`` to mirror iTerm2's default badge placement.
public enum BadgePosition: String, CaseIterable, Sendable, SettingCodable {
    /// Top-left corner.
    case topLeading
    /// Top-right corner (the default, matching iTerm2 badges).
    case topTrailing
    /// Bottom-left corner.
    case bottomLeading
    /// Bottom-right corner.
    case bottomTrailing
    /// Centered horizontally and vertically.
    case center
}
