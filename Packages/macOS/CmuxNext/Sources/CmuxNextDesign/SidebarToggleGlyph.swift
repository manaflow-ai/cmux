public import AppKit

/// The sidebar toggle's drawn glyphs (`SidebarToggleIcon` in CmuxNextApp picks one): template images
/// drawn at the toolbar icon size with the stroke weight of a regular SF Symbol at that size, so they
/// sit beside the traffic lights like the system's toolbar icons. Each has a sidebar-shown and a
/// sidebar-hidden form; `panel` also draws every step between them, so its bar slides.
public nonisolated enum SidebarToggleGlyph: String, Sendable, CaseIterable {
    case panel, railFilled, railOnly, chevronPanel, twoColumn, listRail, thickEdge

    /// The prefix of the names `TitlebarBandButton.symbol` takes for these glyphs.
    public static let prefix = "cmux.sidebarToggle."
    private static let slideSteps = 48

    /// The glyph's name for the sidebar's state.
    public func name(sidebarHidden hidden: Bool) -> String {
        Self.prefix + rawValue + (hidden ? ".hidden" : ".shown")
    }

    /// The `panel` glyph `progress` of the way from its sidebar-shown form (0) to its hidden form (1),
    /// in 48 steps; the ends are `name(sidebarHidden:)`'s names.
    public static func slideName(progress: Double) -> String {
        let step = Int((min(max(progress, 0), 1) * Double(slideSteps)).rounded())
        if step == 0 { return panel.name(sidebarHidden: false) }
        if step == slideSteps { return panel.name(sidebarHidden: true) }
        return prefix + panel.rawValue + ".\(step)"
    }

    /// A template image for a `prefix` name at `pointSize`, or nil for any other name (an SF Symbol).
    public static func image(named name: String, pointSize: CGFloat) -> NSImage? {
        guard name.hasPrefix(prefix) else { return nil }
        let parts = name.dropFirst(prefix.count).split(separator: ".")
        guard parts.count == 2, let glyph = SidebarToggleGlyph(rawValue: String(parts[0])) else { return nil }
        let hidden = parts[1] == "hidden"
        // A slide frame names its step (`slideName(progress:)`).
        let progress = Int(parts[1]).map { Double($0) / Double(slideSteps) } ?? (hidden ? 1 : 0)
        // The box of a regular SF Symbol panel glyph at this point size.
        let size = NSSize(width: (pointSize * 1.38).rounded(), height: (pointSize * 1.1).rounded())
        let image = NSImage(size: size, flipped: true) { rect in
            glyph.draw(hidden: hidden, progress: progress, in: rect, pointSize: pointSize)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draws the glyph in black (the template's mask), y down.
    func draw(hidden: Bool, progress: Double, in canvas: CGRect, pointSize: CGFloat) {
        // A regular SF Symbol's stroke at toolbar sizes (about 1.1 pt at 13 pt).
        let line = max(1, pointSize * 0.085)
        let outer = canvas.insetBy(dx: line / 2 + pointSize * 0.03, dy: line / 2 + pointSize * 0.03)
        let radius = outer.height * 0.22
        let railWidth = (outer.width * 0.34).rounded()
        let dividerX = outer.minX + railWidth
        NSColor.black.setStroke()
        NSColor.black.setFill()

        func stroke(_ path: NSBezierPath) {
            path.lineWidth = line
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        func outline() { stroke(NSBezierPath(roundedRect: outer, xRadius: radius, yRadius: radius)) }
        func divider() {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: dividerX, y: outer.minY))
            path.line(to: CGPoint(x: dividerX, y: outer.maxY))
            stroke(path)
        }

        switch self {
        case .panel:
            outline()
            // Shown: the divider a third in, touching the frame. Hidden: a bar half the height, close to the left edge.
            let t = CGFloat(progress)
            let x = dividerX + (outer.minX + line * 2.5 - dividerX) * t
            let inset = outer.height * 0.27 * t
            let bar = NSBezierPath()
            bar.move(to: CGPoint(x: x, y: outer.minY + inset))
            bar.line(to: CGPoint(x: x, y: outer.maxY - inset))
            stroke(bar)
        case .railFilled:
            outline()
            if hidden {
                divider()
            } else {
                let rail = CGRect(x: outer.minX + line * 1.5, y: outer.minY + line * 1.5,
                                  width: railWidth - line * 2, height: outer.height - line * 3)
                NSBezierPath(roundedRect: rail, xRadius: radius * 0.55, yRadius: radius * 0.55).fill()
            }
        case .railOnly:
            let width = (canvas.width * 0.3).rounded()
            let bar = CGRect(x: canvas.minX + canvas.width * 0.18, y: outer.minY, width: width, height: outer.height)
            let path = NSBezierPath(roundedRect: bar, xRadius: width * 0.42, yRadius: width * 0.42)
            if hidden { stroke(path) } else { path.fill() }
            // A short stub for the content beside it, so the bar reads as a rail.
            let stub = NSBezierPath()
            let x = bar.maxX + line * 2.2
            stub.move(to: CGPoint(x: x, y: outer.minY + outer.height * 0.3))
            stub.line(to: CGPoint(x: outer.maxX - line, y: outer.minY + outer.height * 0.3))
            stub.move(to: CGPoint(x: x, y: outer.minY + outer.height * 0.7))
            stub.line(to: CGPoint(x: outer.maxX - line * 3, y: outer.minY + outer.height * 0.7))
            stroke(stub)
        case .chevronPanel:
            outline()
            divider()
            let content = CGRect(x: dividerX, y: outer.minY, width: outer.maxX - dividerX, height: outer.height)
            let half = outer.height * 0.2
            let path = NSBezierPath()
            let tipX = content.midX + (hidden ? half / 2 : -half / 2)
            let backX = content.midX + (hidden ? -half / 2 : half / 2)
            path.move(to: CGPoint(x: backX, y: content.midY - half))
            path.line(to: CGPoint(x: tipX, y: content.midY))
            path.line(to: CGPoint(x: backX, y: content.midY + half))
            stroke(path)
        case .twoColumn:
            let gap = line * 1.8
            let left = CGRect(x: outer.minX, y: outer.minY, width: railWidth - gap / 2, height: outer.height)
            let right = CGRect(x: outer.minX + railWidth + gap / 2, y: outer.minY,
                               width: outer.maxX - outer.minX - railWidth - gap / 2, height: outer.height)
            let small = radius * 0.8
            let leftPath = NSBezierPath(roundedRect: left, xRadius: small, yRadius: small)
            if hidden { stroke(leftPath) } else { leftPath.fill() }
            stroke(NSBezierPath(roundedRect: right, xRadius: small, yRadius: small))
        case .listRail:
            outline()
            divider()
            let rows = NSBezierPath()
            for fraction in [0.3, 0.5, 0.7] {
                let y = outer.minY + outer.height * fraction
                rows.move(to: CGPoint(x: outer.minX + line * 2.2, y: y))
                rows.line(to: CGPoint(x: dividerX - line * 2.2, y: y))
            }
            NSColor.black.withAlphaComponent(hidden ? 0.4 : 1).setStroke()
            stroke(rows)
        case .thickEdge:
            outline()
            if hidden {
                let path = NSBezierPath()
                let x = outer.minX + outer.width * 0.2
                path.move(to: CGPoint(x: x, y: outer.minY))
                path.line(to: CGPoint(x: x, y: outer.maxY))
                stroke(path)
            } else {
                let bar = CGRect(x: outer.minX, y: outer.minY, width: outer.width * 0.2, height: outer.height)
                let clip = NSBezierPath(roundedRect: outer, xRadius: radius, yRadius: radius)
                NSGraphicsContext.saveGraphicsState()
                clip.addClip()
                NSBezierPath(rect: bar).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}
