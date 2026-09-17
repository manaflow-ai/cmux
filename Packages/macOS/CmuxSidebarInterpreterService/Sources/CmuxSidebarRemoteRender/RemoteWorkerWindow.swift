import AppKit

/// The worker's offscreen layout/coordinate shell.
///
/// **Never ordered onto the screen**: an on-screen window's own CoreAnimation
/// context claims the layer tree and the shared remote context renders blank
/// (spike-verified; the coordinator also steals the layer back after every
/// layout pass). The window exists so AppKit/SwiftUI have a real window for
/// layout and coordinate spaces; forwarded input is hit-tested geometrically,
/// not routed through the window.
final class RemoteWorkerWindow: NSWindow {
    /// Fired whenever a descendant view marks itself as needing display
    /// (AppKit aggregates `setNeedsDisplay` from any view in the window
    /// here). With no display cycle to consume the flag, this signal is how
    /// between-message invalidations reach the coordinator's display pump.
    var onViewsNeedDisplay: (@MainActor () -> Void)?

    /// Allow future focus forwarding; nothing orders this window in, so key
    /// status never affects the user's real windows.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override var viewsNeedDisplay: Bool {
        didSet {
            if viewsNeedDisplay { onViewsNeedDisplay?() }
        }
    }
}
