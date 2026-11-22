import CmuxNextDesign
import CoreGraphics

/// The Chief sidebar's slide, as the details panel of the Messages app
/// moves: one spring-driven reveal fraction (0 closed, 1 open) places both
/// the transcript and the sidebar, so they move in the same frame and the
/// transcript's right edge stays on the sidebar's left edge in every frame.
/// A toggle mid-flight retargets the spring from where the panel is on
/// screen, with its momentum (`SpringValue`): no jump, no queue. Pure, so
/// the state machine is unit-tested without a window.
nonisolated struct HomeSidebarSlide: Equatable, Sendable {
    private(set) var reveal = SpringValue(0)

    /// The requested state (the last click wins).
    var isOpen: Bool { reveal.target == 1 }
    /// The sidebar is on screen: open, or still sliding out.
    var isVisible: Bool { isOpen || reveal.value > 0 }
    /// The spring has not settled (the frame client keeps ticking).
    var isMoving: Bool { reveal.value != reveal.target || reveal.velocity != 0 }

    /// Settled within a quarter point of the 280 pt sidebar.
    static let epsilon: CGFloat = 0.001

    /// A click: animated starts the spring from the current place and
    /// velocity; not animated (Reduce Motion, `ui.animationSpeed` off, no
    /// window) snaps.
    mutating func setOpen(_ open: Bool, animated: Bool) {
        reveal.target = open ? 1 : 0
        if !animated { reveal.snap() }
    }

    /// One display frame. Returns true while the slide still moves.
    mutating func advance(_ dt: Double, policy: MotionPolicy) -> Bool {
        reveal.advance(dt, parameters: policy.spring(isOpen ? .appear : .disappear), epsilon: Self.epsilon)
    }

    /// The transcript and sidebar frames in `bounds` for the presented
    /// reveal. The shared edge is on a device pixel (`scale` is the backing
    /// scale), so it neither shimmers nor leaves a hairline gap.
    func frames(in bounds: CGRect, sidebarWidth: CGFloat, scale: CGFloat) -> (transcript: CGRect, sidebar: CGRect) {
        let fraction = min(max(reveal.value, 0), 1)
        let pixels = max(scale, 1)
        let shown = (sidebarWidth * fraction * pixels).rounded() / pixels
        let edge = bounds.maxX - shown
        let transcript = CGRect(x: bounds.minX, y: bounds.minY, width: max(0, edge - bounds.minX), height: bounds.height)
        let sidebar = CGRect(x: edge, y: bounds.minY, width: sidebarWidth, height: bounds.height)
        return (transcript, sidebar)
    }
}
