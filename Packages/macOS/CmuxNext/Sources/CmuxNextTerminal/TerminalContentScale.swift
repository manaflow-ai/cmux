import CoreGraphics

/// Where a terminal's backing scale and display go: its root layer, then its Ghostty surface
/// (``TerminalContentScale``). A test records the calls and their order.
@MainActor
protocol TerminalScaleTarget: AnyObject {
    /// The root layer's `contentsScale`; nil with no layer.
    var rootLayerScale: CGFloat? { get }
    func setRootLayerScale(_ scale: CGFloat)
    /// `ghostty_surface_set_content_scale` (ghostty.h:1440).
    func setContentScale(_ scale: CGSize)
    /// `ghostty_surface_set_display_id` (ghostty.h:1821).
    func setDisplayID(_ id: UInt32)
}

/// The backing a shown terminal draws at, read from its window.
struct TerminalBacking: Equatable {
    /// The window's `backingScaleFactor`; nil outside a window.
    var windowScale: CGFloat?
    /// One point of the view in backing pixels (`convertToBacking`).
    var contentScale: CGSize
    /// The window's screen (`NSScreenNumber`); nil without one.
    var displayID: UInt32?
}

/// Gives a terminal its backing scale and display, only what changed since the last call (a terminal shown
/// again calls it). The root layer's scale goes first: ghostty-next's renderer copies the root layer's
/// `contentsScale` to its own layer on each content scale and size (src/renderer/metal/DrawablePresenter.zig),
/// as upstream Ghostty's SurfaceView_AppKit `viewDidChangeBackingProperties` orders it.
struct TerminalContentScale {
    private(set) var appliedContentScale: CGSize?
    /// The display ID last given to the surface; nil before it is first shown.
    private(set) var appliedDisplayID: UInt32?

    mutating func apply(_ backing: TerminalBacking, to target: some TerminalScaleTarget) {
        if let windowScale = backing.windowScale, let layerScale = target.rootLayerScale, layerScale != windowScale {
            target.setRootLayerScale(windowScale)
        }
        if backing.contentScale != appliedContentScale {
            appliedContentScale = backing.contentScale
            target.setContentScale(backing.contentScale)
        }
        if let displayID = backing.displayID, displayID != appliedDisplayID {
            appliedDisplayID = displayID
            target.setDisplayID(displayID)
        }
    }
}
