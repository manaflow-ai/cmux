import Foundation

/// Corner of the terminal surface where the scroll-fixed badge overlay is
/// anchored. Stored under ``TerminalCatalogSection/badgePosition``.
///
/// Cases use leading/trailing semantics so the anchor automatically mirrors
/// for right-to-left layouts; the settings UI presents them with left/right
/// labels for the languages cmux currently ships.
public enum TerminalBadgePosition: String, CaseIterable, Sendable, SettingCodable {
    /// Top-left corner (top-right under right-to-left layouts).
    case topLeading
    /// Top-right corner (top-left under right-to-left layouts).
    case topTrailing
    /// Bottom-left corner (bottom-right under right-to-left layouts).
    case bottomLeading
    /// Bottom-right corner (bottom-left under right-to-left layouts).
    case bottomTrailing
}
