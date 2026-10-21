import AppKit
import CmuxNextDesign
import QuartzCore

/// A group header's bar and, with `sidebar.groupLineJoinsHeader`, its members' line as one
/// outline on the header's pill layer (`SidebarGroupLineShape.joined`, Leo 2026-10-19). With an
/// animated reload or fold the joined line springs to its new length on the rows' own `.move`
/// spring, so its end stays at the group's last row in every frame (#21999 review).
@MainActor final class GroupHeaderJoinedBar {
    private let pill: CALayer
    /// Lays the header out again once a line closing into its bar is back in it.
    private let relayout: @MainActor () -> Void
    /// The joined line's length the outline was last given; a line closing into its bar keeps the
    /// joined outline (`unjoining`) until its spring ends.
    private var drawn: CGFloat = 0
    private var unjoining = false
    private var springCount = 0

    init(_ pill: CALayer, relayout: @escaping @MainActor () -> Void) {
        self.pill = pill
        self.relayout = relayout
    }

    /// Draws the bar at `bar` with its joined line `length` below it; 0 draws the plain rounded bar.
    func layOut(bar: NSRect, length: CGFloat, radius: CGFloat, springs: Bool) {
        let springs = springs && length != drawn
        if length > 0 || unjoining || (springs && drawn > 0) {
            layOutJoined(bar: bar, length: length, radius: radius, springs: springs)
        } else {
            removeSprings()
            pill.frame = bar
            pill.cornerRadius = radius // one radius with the pinned and workspace rows
            pill.mask = nil
            drawn = 0
        }
    }

    /// Springing, the pill and its outline move from what is on screen on the rows' spring; a line
    /// closing to 0 keeps the joined outline until it is back in the bar, then the plain rounded
    /// bar takes over.
    private func layOutJoined(bar: NSRect, length: CGFloat, radius: CGFloat, springs: Bool) {
        let frame = NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: bar.height + length)
        let path = SidebarGroupLineShape.joined(width: bar.width, barHeight: bar.height, radius: radius,
                                                lineWidth: SidebarStyle.groupBarWidth, length: length)
        let fresh = !(pill.mask is CAShapeLayer)
        let outline = pill.mask as? CAShapeLayer ?? CAShapeLayer()
        outline.anchorPoint = .zero
        outline.position = .zero
        pill.cornerRadius = 0
        pill.mask = outline
        guard springs else {
            if length != drawn { removeSprings() }
            pill.frame = frame
            outline.bounds = CGRect(origin: .zero, size: frame.size)
            outline.path = path
            drawn = length
            return
        }
        // A line that starts joining grows from the bar alone.
        let start = fresh ? SidebarGroupLineShape.joined(width: bar.width, barHeight: bar.height, radius: radius,
                                                         lineWidth: SidebarStyle.groupBarWidth, length: 0) : nil
        let startBounds = fresh ? NSValue(rect: CGRect(origin: .zero, size: bar.size)) : nil
        drawn = length
        unjoining = length == 0
        springCount += 1
        let spring = springCount
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { // main-proof: CATransaction.h: the completion block is called on the main thread
                guard let self, self.springCount == spring, self.unjoining else { return }
                self.unjoining = false
                self.relayout()
            }
        }
        Motion.sidebar.set(pill, "bounds", to: NSValue(rect: CGRect(origin: .zero, size: frame.size)), spring: .move, from: startBounds)
        Motion.sidebar.set(pill, "position", to: NSValue(point: CGPoint(x: frame.midX, y: frame.midY)), spring: .move,
                           from: fresh ? NSValue(point: CGPoint(x: bar.midX, y: bar.midY)) : nil)
        Motion.sidebar.set(outline, "bounds", to: NSValue(rect: CGRect(origin: .zero, size: frame.size)), spring: .move, from: startBounds)
        Motion.sidebar.set(outline, "path", to: path, spring: .move, from: start)
        CATransaction.commit()
    }

    private func removeSprings() {
        ["bounds", "position"].forEach(pill.removeAnimation(forKey:))
        ["bounds", "path"].forEach { pill.mask?.removeAnimation(forKey: $0) }
        unjoining = false
    }
}
