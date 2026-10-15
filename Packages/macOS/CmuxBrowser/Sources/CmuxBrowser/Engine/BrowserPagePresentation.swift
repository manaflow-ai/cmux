import Foundation

/// How a page puts pixels on screen.
///
/// Callers use this, never the engine kind, to decide whether overlays may
/// sit above the page content.
public enum BrowserPagePresentation: Equatable, Hashable, Sendable {
    /// The content is a normal view inside ``BrowserPage/contentView``.
    case inView
    /// The content is a separate child window that tracks
    /// ``BrowserPage/contentView``. Overlays must be separate panels above it.
    case childWindow
}
