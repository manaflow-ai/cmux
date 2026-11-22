import AppKit
import CmuxNextDesign

/// The sidebar toggle's glyph (cx-uxdr, Lawrence 2026-10-08: "make more
/// choices in debug menu, come up with better designs"). A DEV and NIGHTLY
/// switch in Debug Settings (section "Sidebar and Window") and in the
/// Debug menu ("Sidebar Toggle Icon"); it changes the toggle in every
/// window at once. The default stays `current` until Lawrence picks.
///
/// SF Symbol candidates use system glyphs. Custom candidates are template
/// images drawn at the toolbar icon size with the stroke weight of a
/// regular SF Symbol at that size, so they sit beside the traffic lights
/// like the system's toolbar icons. Each candidate has a sidebar-shown and
/// a sidebar-hidden form: a filled rail (or a left chevron) means "the
/// sidebar is open, click to close"; an empty rail (or a right chevron)
/// means "click to open".
nonisolated enum SidebarToggleIcon: String, Sendable, CaseIterable, TunableChoice {
    /// The arrow-into-panel glyph while shown, the sidebar glyph while hidden.
    case current
    /// SF Symbol `sidebar.left` in both states (the system toolbar glyph).
    case sidebarLeft
    /// SF Symbol `sidebar.squares.left` in both states.
    case sidebarSquares
    /// SF Symbol `rectangle.leftthird.inset.filled` in both states.
    case leftThird
    /// A thin panel outline with an inset filled left rail (empty when hidden).
    case railFilled
    /// The rail alone: a rounded bar, filled while shown, outlined while hidden.
    case railOnly
    /// A panel with a rail line and a chevron: left to close, right to open.
    case chevronPanel
    /// Two separate columns, a narrow one and a wide one; the narrow one fills.
    case twoColumn
    /// A panel whose rail holds three list rows (faint while hidden).
    case listRail
    /// A panel whose left edge is a thick bar (a thin divider while hidden).
    case thickEdge

    /// The Debug Settings switch (the Debug menu writes the same value).
    static let tunable = Tunable<SidebarToggleIcon>.choice(
        "sidebar.toggleIcon", .sidebar, "Sidebar toggle icon",
        help: "The glyph of the sidebar toggle right of the traffic lights. Candidates for review; the default is unchanged until one is picked.",
        default: .current, code: "SidebarToggleIcon.tunable")

    /// `current` while the sidebar shows: collapse it to the left.
    static let currentCollapseSymbol = "rectangle.lefthalf.inset.filled.arrow.left"
    /// `current` while the sidebar is hidden: the sidebar.
    static let currentExpandSymbol = "sidebar.left"

    /// The prefix of the names `TitlebarBandButton.symbol` takes for a custom glyph.
    static let customPrefix = "cmux.sidebarToggle."

    /// Whether this candidate is drawn here (not an SF Symbol).
    var isCustom: Bool {
        switch self {
        case .current, .sidebarLeft, .sidebarSquares, .leftThird: false
        case .railFilled, .railOnly, .chevronPanel, .twoColumn, .listRail, .thickEdge: true
        }
    }

    /// The glyph name for the sidebar's state: an SF Symbol name, or a
    /// `customPrefix` name `image(named:pointSize:)` draws.
    func symbol(sidebarHidden hidden: Bool) -> String {
        switch self {
        case .current: hidden ? Self.currentExpandSymbol : Self.currentCollapseSymbol
        case .sidebarLeft: "sidebar.left"
        case .sidebarSquares: "sidebar.squares.left"
        case .leftThird: "rectangle.leftthird.inset.filled"
        default: Self.customPrefix + rawValue + (hidden ? ".hidden" : ".shown")
        }
    }

    var tunableTitle: String {
        switch self {
        case .current: String(localized: "sidebarToggleIcon.current", defaultValue: "Arrow (current)", bundle: .module)
        case .sidebarLeft: String(localized: "sidebarToggleIcon.sidebarLeft", defaultValue: "Sidebar", bundle: .module)
        case .sidebarSquares: String(localized: "sidebarToggleIcon.sidebarSquares", defaultValue: "Sidebar with Squares", bundle: .module)
        case .leftThird: String(localized: "sidebarToggleIcon.leftThird", defaultValue: "Left Third", bundle: .module)
        case .railFilled: String(localized: "sidebarToggleIcon.railFilled", defaultValue: "Panel with Filled Rail", bundle: .module)
        case .railOnly: String(localized: "sidebarToggleIcon.railOnly", defaultValue: "Rail Only", bundle: .module)
        case .chevronPanel: String(localized: "sidebarToggleIcon.chevronPanel", defaultValue: "Panel with Chevron", bundle: .module)
        case .twoColumn: String(localized: "sidebarToggleIcon.twoColumn", defaultValue: "Two Columns", bundle: .module)
        case .listRail: String(localized: "sidebarToggleIcon.listRail", defaultValue: "Rail with Rows", bundle: .module)
        case .thickEdge: String(localized: "sidebarToggleIcon.thickEdge", defaultValue: "Thick Edge", bundle: .module)
        }
    }

    // MARK: Custom glyphs

    /// A template image for a `customPrefix` name at `pointSize`, or nil
    /// for any other name (an SF Symbol).
    static func image(named name: String, pointSize: CGFloat) -> NSImage? {
        guard name.hasPrefix(customPrefix) else { return nil }
        let parts = name.dropFirst(customPrefix.count).split(separator: ".")
        guard parts.count == 2, let icon = SidebarToggleIcon(rawValue: String(parts[0])), icon.isCustom else { return nil }
        let hidden = parts[1] == "hidden"
        // The box of a regular SF Symbol panel glyph at this point size.
        let size = NSSize(width: (pointSize * 1.38).rounded(), height: (pointSize * 1.1).rounded())
        let image = NSImage(size: size, flipped: true) { rect in
            icon.draw(hidden: hidden, in: rect, pointSize: pointSize)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = icon.tunableTitle
        return image
    }

    /// Draws the glyph in black (the template's mask), y down.
    private func draw(hidden: Bool, in canvas: CGRect, pointSize: CGFloat) {
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
        case .current, .sidebarLeft, .sidebarSquares, .leftThird:
            break
        }
    }
}
