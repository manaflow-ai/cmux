import CmuxNextDesignTokens
import CoreGraphics

/// The conversation list's slide in and out (the Chats button), as the Mac's own sidebars move
/// (Messages, Notes, Mail; the person, 2026-11-23: "sidebar closing / opening transition should be
/// much better and should match transitions of popular sidebar"): the list keeps its width and
/// slides in from the page's leading edge while the chat narrows beside it, and back out while
/// the chat widens; no fade, no squeeze of the rows. ``reveal`` is how much of the list shows, in
/// points: 0 folded, the list's width open. It runs on the sidebar springs (`appear` to show,
/// `disappear` to hide; neither passes its target), so a second click mid-slide turns it around
/// from where it is with the speed it has, never a jump.
struct HomeSidebarSlide: Equatable {
    private(set) var spring: SpringValue
    private(set) var parameters: SpringParameters

    /// The sidebar spring at its base speed: `appear` to show, `disappear` to fold (the view asks
    /// its window's motion policy instead, which scales it and stops it under Reduce Motion).
    static func baseSpring(open: Bool) -> SpringParameters { (open ? MotionSpring.appear : .disappear).base }

    /// A slide from `from` points showing to `to`.
    init(from: CGFloat, to: CGFloat, parameters: SpringParameters) {
        spring = SpringValue(from)
        spring.target = to
        self.parameters = parameters
    }

    /// How much of the list shows now (the view clamps it to the list's width).
    var reveal: CGFloat { spring.value }

    var target: CGFloat { spring.target }

    /// Turns toward `to` from where it is, keeping its speed.
    mutating func retarget(_ to: CGFloat, parameters: SpringParameters) {
        spring.target = to
        self.parameters = parameters
    }

    /// One display frame of `dt` seconds.
    mutating func advance(_ dt: Double) {
        spring.step(dt, parameters: parameters)
    }

    /// Close enough to land: under half a point away and slower than 4 points a second.
    var isSettled: Bool { abs(spring.value - spring.target) < 0.5 && abs(spring.velocity) < 4 }
}
