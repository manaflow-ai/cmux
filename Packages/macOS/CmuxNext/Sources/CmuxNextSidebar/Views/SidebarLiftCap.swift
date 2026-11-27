import AppKit
import CmuxNextDesign
import QuartzCore

/// The bottom-edge fade of a lifted group cut to its header and first rows (`DragLiftView.cap(to:fade:)`;
/// Lawrence 2026-10-23: "groups that are too tall, when i drag around, get a max height, animated").
///
/// A mask on the card's content: opaque down to `fade` above the card's bottom, clear at the bottom, so the rows
/// past the cut fade out under the edge. The edge rides on the card's bottom on the card's own move spring: it
/// starts at the uncut bottom, moves up as the card shrinks, and moves past the content when the card grows back
/// to the whole group (a landing), so nothing is faded then.
@MainActor final class SidebarLiftCap {
    /// The content's uncut height (the whole group).
    let full: CGFloat
    /// How tall the fading edge is.
    let fade: CGFloat
    /// The content layer's mask.
    let mask = CAGradientLayer()

    init(full: CGFloat, fade: CGFloat) {
        self.full = full
        self.fade = max(1, fade)
        // From the top (the content is flipped, y down): opaque, then clear over the last `fade` points.
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        let height = full + self.fade
        mask.locations = [0, NSNumber(value: Double(full / height)), 1]
    }

    /// The mask's frame for a card `height` tall and `width` wide: its fading edge ends at the card's bottom, or
    /// past the content when the card shows the whole group.
    func frame(height: CGFloat, width: CGFloat) -> CGRect {
        let bottom = height >= full - 0.5 ? full + fade : height
        return CGRect(x: 0, y: bottom - full - fade, width: width, height: full + fade)
    }

    /// Puts the edge at the bottom of a card `height` tall; `animated`: on the move spring, from where it is on screen.
    func place(height: CGFloat, width: CGFloat, animated: Bool) {
        let target = frame(height: height, width: width)
        let start = mask.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = target
        CATransaction.commit()
        guard animated, start != mask.position else { return }
        let delta = NSValue(point: NSPoint(x: start.x - mask.position.x, y: start.y - mask.position.y))
        let animation = Motion.sidebar.springAnimation(.move, "position", from: delta, to: NSValue(point: .zero))
        animation.isAdditive = true
        mask.add(animation, forKey: "cap.position.\(serial)")
        serial &+= 1
    }

    private var serial = 0
}
