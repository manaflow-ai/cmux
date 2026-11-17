import Foundation

/// The light around a zoom, for one screen: the other panes dim, and no pane moves under the dim.
///
/// - A zoom waits (``Phase/coming``): the screen shows the layout before it, whole, while the dim comes over the other
///   panes. When the dim's fade is over, one frame shows the zoomed pane alone and the dim leaves with it.
/// - An unzoom shows every pane at its place in one frame, the others under the dim (``Phase/going``), which fades out
///   and leaves when its fade is over.
///
/// The fade runs on the render server; this state counts its time in the layout's frame ticks, so the frame that
/// shows a zoom, and the one that takes the dim away, are the layout's own.
struct PaneZoomDim {
    enum Phase {
        /// No dim shows.
        case none
        /// The dim comes over the layout before a zoom; the zoom shows when ``remaining`` is spent.
        case coming
        /// The dim goes over the layout an unzoom showed; it leaves when ``remaining`` is spent.
        case going
    }

    var phase: Phase = .none
    /// Seconds of frame time left in the phase.
    var remaining: TimeInterval = 0
    /// The pane an unzoom gives its place back to: the dim comes with the frame that shows that unzoom.
    var returning: PaneID?
    weak var view: PaneZoomDimView?

    /// The longest the dim's fade may take, whatever the animation speed.
    static let longest: TimeInterval = 0.3
}
