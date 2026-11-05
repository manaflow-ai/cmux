import AppKit
import CoreGraphics
import CoreText

/// An agents row as one pill per agent, the ChatGPT look (user 2026-11-03, msg 19960): a status icon (a
/// spinner while it works, a check once it reported, a cross when it stopped), its title, an unread dot
/// for a report and a `›`. The shipped look of an agents row (``HomeAgentFoldRowProvider``); the DEBUG
/// playground's pill styles draw its other shapes. One layout for drawing and hit-testing, so a click
/// always lands on the pill it is drawn on. Pure CoreGraphics and CoreText, any thread.
struct HomeAgentPills {
    /// The pill shapes: stacked full pills, stacked two-line pills, or small chips in one row.
    enum Shape: Sendable { case pill, twoLine, chip }

    struct Pill {
        let peer: String
        let title: String
        let state: String
        /// The unread dot: a report newer than the one the person last opened.
        let unread: Bool
        let rect: CGRect
    }

    let shape: Shape
    let pills: [Pill]
    let height: CGFloat

    static let gap: CGFloat = 6
    static let padY: CGFloat = 4

    /// Laid out from the row's left edge for `width`.
    init(_ p: HomeAgentFoldRowProvider.Payload, shape: Shape, width: CGFloat) {
        self.shape = shape
        let titles = p.titles.count == p.peers.count ? p.titles : p.peers
        var out: [Pill] = []
        var x: CGFloat = 0, y = Self.padY
        let tall = Self.pillHeight(shape)
        for (i, peer) in p.peers.enumerated() {
            let title = titles[checked: i] ?? peer
            let state = p.states[checked: i] ?? "told"
            let w = min(max(120, Self.contentWidth(title, shape: shape)), max(120, width - 8))
            // Chips keep one row (the row's height does not depend on its width): the rest are left out.
            if shape == .chip, x > 0, x + w > width - 8 { break }
            let unread = p.unread[checked: i] ?? (state == "reported")
            out.append(Pill(peer: peer, title: title, state: state, unread: unread, rect: CGRect(x: x, y: y, width: w, height: tall)))
            if shape == .chip { x += w + Self.gap } else { y += tall + Self.gap }
        }
        pills = out
        let bottom = out.map(\.rect.maxY).max() ?? Self.padY
        height = max(HomeAgentFoldRowProvider.height, bottom + Self.padY)
    }

    static func pillHeight(_ shape: Shape) -> CGFloat {
        switch shape {
        case .pill: 36
        case .twoLine: 50
        case .chip: 26
        }
    }

    private static func titleFont(_ shape: Shape) -> NSFont { HomeFonts.system(ofSize: shape == .chip ? 12 : 14, weight: .medium) }

    /// Icon, title, dot and chevron with their paddings.
    private static func contentWidth(_ title: String, shape: Shape) -> CGFloat {
        let text = NSAttributedString(string: title, attributes: [.font: titleFont(shape)])
        let side: CGFloat = shape == .chip ? 10 : 14
        let icon: CGFloat = shape == .chip ? 14 : 18
        return side + icon + 8 + min(320, HomeTableGrid.lineWidth(text)) + 10 + 8 + 12 + side
    }

    /// The agent whose pill holds `point` (row coordinates), or nil.
    func peer(at point: CGPoint) -> String? {
        pills.first { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }?.peer
    }

    func draw(_ ctx: CGContext, origin: CGPoint) {
        let fill = Fixture.incoming
        let ink = Fixture.incomingText
        let muted = Fixture.secondaryText
        for pill in pills {
            let r = pill.rect.offsetBy(dx: origin.x, dy: origin.y)
            let radius = shape == .twoLine ? 14 : r.height / 2
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            let side: CGFloat = shape == .chip ? 10 : 14
            let iconSize: CGFloat = shape == .chip ? 14 : 18
            let mid = shape == .twoLine ? r.minY + 18 : r.midY
            icon(ctx, state: pill.state, center: CGPoint(x: r.minX + side + iconSize / 2, y: mid), size: iconSize, color: muted)
            let textX = r.minX + side + iconSize + 8
            let right = r.maxX - side
            // The chevron, then the unread dot left of it.
            chevron(ctx, center: CGPoint(x: right - 4, y: shape == .twoLine ? r.midY : mid), color: muted)
            let unread = pill.unread
            if unread { dot(ctx, center: CGPoint(x: right - 20, y: mid), radius: 3.5, color: NSColor.systemBlue) }
            let titleRoom = right - (unread ? 30 : 16) - textX
            let title = NSAttributedString(string: pill.title, attributes: [.font: Self.titleFont(shape), .foregroundColor: ink])
            line(ctx, title, x: textX, mid: mid, width: titleRoom)
            #if DEBUG
            // The two-line shape is the DEBUG playground's alone; its status words are DEV-only English.
            if shape == .twoLine {
                let status = switch pill.state {
                case "reported": "Reported · \(pill.peer)"
                case "stopped": "Stopped without a report · \(pill.peer)"
                default: "Working · \(pill.peer)"
                }
                let sub = NSAttributedString(string: status, attributes: [.font: HomeFonts.system(ofSize: 12, weight: .regular), .foregroundColor: muted])
                line(ctx, sub, x: textX, mid: r.minY + 35, width: titleRoom)
            }
            #endif
        }
    }
}

// MARK: Drawing helpers (pure CoreGraphics and CoreText, any thread)

private func line(_ ctx: CGContext, _ text: NSAttributedString, x: CGFloat, mid: CGFloat, width: CGFloat) {
    guard width > 12, text.length > 0 else { return }
    let full = CTLineCreateWithAttributedString(text)
    let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: text.attributes(at: 0, effectiveRange: nil)))
    let shown = CTLineCreateTruncatedLine(full, Double(width), .end, token) ?? full
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    _ = CTLineGetTypographicBounds(shown, &ascent, &descent, &leading)
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x, y: mid + (ascent - descent) / 2)
    CTLineDraw(shown, ctx)
    ctx.restoreGState()
}

private func dot(_ ctx: CGContext, center c: CGPoint, radius: CGFloat, color: NSColor) {
    ctx.saveGState()
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
    ctx.restoreGState()
}

private func chevron(_ ctx: CGContext, center c: CGPoint, color: NSColor) {
    ctx.saveGState()
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(1.6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: c.x - 2, y: c.y - 4.5))
    ctx.addLine(to: CGPoint(x: c.x + 2.5, y: c.y))
    ctx.addLine(to: CGPoint(x: c.x - 2, y: c.y + 4.5))
    ctx.strokePath()
    ctx.restoreGState()
}

/// The status icon: a check (reported), a cross (stopped), else a spinner arc (working).
private func icon(_ ctx: CGContext, state: String, center c: CGPoint, size: CGFloat, color: NSColor) {
    let r = size / 2 - 1.5
    ctx.saveGState()
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(1.6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    switch state {
    case "reported":
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.move(to: CGPoint(x: c.x - r * 0.45, y: c.y + r * 0.02))
        ctx.addLine(to: CGPoint(x: c.x - r * 0.1, y: c.y + r * 0.38))
        ctx.addLine(to: CGPoint(x: c.x + r * 0.5, y: c.y - r * 0.35))
        ctx.strokePath()
    case "stopped":
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        let k = r * 0.38
        ctx.move(to: CGPoint(x: c.x - k, y: c.y - k)); ctx.addLine(to: CGPoint(x: c.x + k, y: c.y + k))
        ctx.move(to: CGPoint(x: c.x + k, y: c.y - k)); ctx.addLine(to: CGPoint(x: c.x - k, y: c.y + k))
        ctx.strokePath()
    default:
        ctx.setStrokeColor(color.withAlphaComponent(0.25).cgColor)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.setStrokeColor(color.cgColor)
        ctx.addArc(center: c, radius: r, startAngle: -.pi / 2, endAngle: .pi * 0.35, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()
}
