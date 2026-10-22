public import AppKit

/// How often the Chromium hosts of a window answered the fork's geometry
/// reads and asked it for updates (`debug.cef` `geometry`). A bench takes the
/// difference of two reads around a gesture.
public struct CEFGeometryCounters: Equatable, Sendable {
    /// Chromium host views in the window (one per pane that shows a page).
    public var hosts = 0
    /// Clip shapes built (CGPath boolean operations).
    public var clipBuilds = 0
    /// `cmuxClipPath` and `cmuxOcclusionRects` reads by the fork.
    public var reads = 0
    /// Geometry updates asked of the fork.
    public var posts = 0
    /// Updates not asked because the host showed no page (hidden, no window).
    public var skippedPosts = 0

    /// Zero counters.
    public init() {}

    /// The sums over every Chromium host view in `window`'s view tree.
    @MainActor
    public init(window: NSWindow) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let host = view as? CEFHostView {
                hosts += 1
                clipBuilds += host.clipShapeBuilds
                reads += host.geometryReads
                posts += host.geometryPosts
                skippedPosts += host.skippedGeometryPosts
            }
            stack += view.subviews
        }
    }
}
