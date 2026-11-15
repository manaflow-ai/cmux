import AppKit
import QuartzCore

/// The rounded clip around a pane's content. `masksToBounds` with a corner
/// radius clips every sublayer, Metal layers included. Corners are circular
/// (not continuous) so the Chromium page mask, a circular-arc path built
/// from this layer's radius, matches them exactly.
final class PaneClipView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    func setCornerRadius(_ radius: CGFloat) {
        guard let layer, layer.cornerRadius != radius else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius
        CATransaction.commit()
    }

    /// The ground beside and beyond held content (``showHeldGround(_:around:header:footer:leading:)``): at most one part
    /// beyond its top or bottom edge and one beside it, in the view tree only while they show.
    private let heldGrounds = [PaneHeldGroundView(), PaneHeldGroundView()]

    /// SPLIT OPEN CHAT: content its provider holds in motion (an agent chat) has its REST size from a spring's first
    /// frame (`PaneHostView.contentFrame`). A pane that is still larger than its rest (the pane a Split Down halves)
    /// had nothing between that content's edge and its own, so the window's color showed there for the frames of the
    /// spring (2 to 7 at 120 Hz). Chromium shows a resized page's old content on the page's own ground until the new
    /// frame comes; a pane does the same: `color` (the content's own ground, `NSView.paneGroundColor`) fills the part
    /// of this view that `content` (the held content's frame here) does not cover, in the frame that places the pane.
    /// It is measured from where the content IS, not from the pane's edges: the content has its tabs with it (a strip
    /// `header` points high at its top edge or `footer` points high at its bottom edge, a vertical list `leading`
    /// points wide), and no ground goes behind them or beside their rows (Leo 2026-11-03: no backing behind the tabs).
    /// The header and the list are where the content's own area starts (`NSView.paneGroundInsets`), not the header its
    /// pane reports for its ring: a chat with no strip paints from its top edge, so its ground is there too.
    /// Nothing waits and no content lays out again. Nil, a translucent color or content that covers this view removes it.
    func showHeldGround(_ color: CGColor?, around content: CGRect = .zero, header: CGFloat = 0, footer: CGFloat = 0, leading: CGFloat = 0) {
        let color = color.flatMap { $0.alpha >= 1 ? $0 : nil }
        let rects = color == nil ? [] : Self.heldGroundRects(clip: bounds, content: content, header: header, footer: footer, leading: leading)
        for (index, ground) in heldGrounds.enumerated() {
            guard let color, index < rects.count else {
                if ground.superview != nil { ground.removeFromSuperview() }
                continue
            }
            if ground.superview !== self { addSubview(ground, positioned: .below, relativeTo: nil) }
            if ground.frame != rects[index] { ground.frame = rects[index] }
            guard let layer = ground.layer, layer.backgroundColor != color else { continue }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = color
            CATransaction.commit()
        }
    }

    /// The largest gap between held content's edge and its pane's that is no gap: under a hundredth of a point, which is
    /// less than a pixel at every backing scale.
    static let heldGroundSlack: CGFloat = 0.01

    /// The parts of `clip` that held content at `content` leaves open and its ground fills (both in one flipped space:
    /// minY is the top). The content's area is `content` less its own tabs. Beyond the content's top or bottom edge: the
    /// columns of that area (below a strip at the bottom, above a strip at the top; a vertical list's column stays
    /// clear). Beside the content: the rows of that area, and the rows of the part beyond (the corner). Content is
    /// pinned at one edge of each axis, so there are at most two parts. A part one pixel thick is a part: a 2x screen
    /// places a spring's last frames half a point from the rest, and that pixel showed the window's color at the far
    /// edge. Only a difference no screen can show (``heldGroundSlack``, float noise of the frame math) is none.
    static func heldGroundRects(clip: CGRect, content: CGRect, header: CGFloat, footer: CGFloat, leading: CGFloat) -> [CGRect] {
        let columns = (min: min(content.minX + max(0, leading), content.maxX), max: content.maxX)
        var rows = (min: min(content.minY + max(0, header), content.maxY), max: max(content.maxY - max(0, footer), content.minY))
        guard columns.max - columns.min > 0, rows.max - rows.min > 0 else { return [] }
        var rects: [CGRect] = []
        if content.maxY < clip.maxY - heldGroundSlack {
            rects.append(CGRect(x: columns.min, y: content.maxY, width: columns.max - columns.min, height: clip.maxY - content.maxY))
            rows.max = clip.maxY
        } else if content.minY > clip.minY + heldGroundSlack {
            rects.append(CGRect(x: columns.min, y: clip.minY, width: columns.max - columns.min, height: content.minY - clip.minY))
            rows.min = clip.minY
        }
        if content.maxX < clip.maxX - heldGroundSlack {
            rects.append(CGRect(x: content.maxX, y: rows.min, width: clip.maxX - content.maxX, height: rows.max - rows.min))
        } else if content.minX > clip.minX + heldGroundSlack {
            rects.append(CGRect(x: clip.minX, y: rows.min, width: content.minX - clip.minX, height: rows.max - rows.min))
        }
        return rects
    }
}

/// A part of a pane's ground beside its held content (``PaneClipView/showHeldGround(_:around:header:footer:leading:)``): a color, no clicks.
private final class PaneHeldGroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
