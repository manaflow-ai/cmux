import Foundation

/// Why a page of a lazily started engine is likely soon.
public enum BrowserEngineWarmupReason: String, CaseIterable, Hashable, Sendable {
    /// A restored session holds a page of this engine.
    case restoredPage
    /// The user opened a menu that offers a page of this engine.
    case newPageMenu
    /// The user selected or hovered a command palette entry that opens one.
    case palette
    /// A browser page exists and new browser pages default to this engine.
    case browserPage
    /// The default engine was just switched to this engine.
    case defaultEngine
}
