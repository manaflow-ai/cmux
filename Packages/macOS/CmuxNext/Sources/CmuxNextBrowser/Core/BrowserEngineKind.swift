public import Foundation

/// The engine that renders a tab. Fixed at tab creation; "reopen in other
/// engine" creates a new tab with the same URL.
public nonisolated enum BrowserEngineKind: String, Hashable, Sendable, Codable, CaseIterable {
    case webkit
    case cef
}

/// How an engine puts pixels on screen. Callers use this, never the engine
/// kind, to decide whether glass or overlays may sit above the content.
public nonisolated enum BrowserPresentation: Hashable, Sendable {
    /// The content is a normal view inside `BrowserTab.contentView`.
    case inView
    /// The content is a separate child window that tracks `contentView`
    /// (CEF Chrome style). Overlays must be separate panels above it, and the
    /// tab must be occluded during animations.
    case childWindow
}
