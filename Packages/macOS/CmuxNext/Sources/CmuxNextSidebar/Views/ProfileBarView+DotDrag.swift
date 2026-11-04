import AppKit
import CmuxNextDesign

// Space dot drag reorder (unimplemented audit row 14): a dot pressed and dragged lifts and
// follows the pointer along the strip; the other dots spring to the order a drop would give
// (the sidebar's one drag feel, `MotionSpring.selection`); a release over the footer band moves
// the space with the same reorder as the space menu's Move Left / Move Right
// (`SidebarIntent.reorderProfile`, `move-profile`). A release off the band moves nothing: the
// dots spring back. A release outside the window opens the space in a new window
// (`SidebarIntent.openProfileInNewWindow`, Open Space in New Window; spaces-overhaul-DESIGN.md rule 4)
// and the dots spring back: the space stays in this window. A press that does not move past the
// drag threshold stays a click.
extension ProfileBarView {
    /// The spaces in the order the strip shows during a dot drag; nil while no dot is dragged.
    var previewOrder: [ProfileKey]? {
        dotDrag.map { ProfileBarDotDrag.order(model.profiles.map(\.id), moving: $0.from, to: $0.target) }
    }

    /// The pressed dot follows `point` (bar coordinates) once the press moved past the threshold.
    func dragDot(to point: NSPoint) {
        if dotDrag == nil {
            guard let pressed, let start = pressPoint, model.profiles.indices.contains(pressed), model.profiles.count > 1,
                  dotIsDrawn(at: pressed), SidebarPress.movedPastThreshold(from: start, to: point) else { return }
            beginDotDrag(pressed, at: start)
        }
        guard let drag = dotDrag, !drag.landing else { return }
        let centers = slotRects().prefix(model.profiles.count).map(\.midX)
        guard let first = centers.first, let last = centers.last else { return }
        let x = min(max(point.x - drag.grab, first), last)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drag.dots[drag.from].removeAnimation(forKey: "position")
        drag.dots[drag.from].position = CGPoint(x: x, y: bounds.midY)
        CATransaction.commit()
        drag.overBand = footerBand(contains: point)
        drag.outsideWindow = outsideWindow(point)
        let target = drag.overBand ? ProfileBarLogic.dropPosition(from: drag.from, x: Double(x), centers: centers.map { Double($0) }) : drag.from
        guard target != drag.target else { return }
        drag.target = target
        placeDots(drag, includingDragged: false)
    }

    /// The release of a dot drag: drops it (true), or false when no dot was dragged (a click).
    func dropDot() -> Bool {
        guard let drag = dotDrag, !drag.landing else { return dotDrag != nil }
        drag.landing = true
        if drag.outsideWindow { model.send(.openProfileInNewWindow(model.profiles[drag.from].id)) }
        if !drag.overBand || drag.outsideWindow { drag.target = drag.from }
        // The insertion index of `move-profile` (an index before removal), as Move Right/Left send it.
        if let insertion = ProfileBarLogic.moveInsertion(from: drag.from, to: drag.target, count: model.profiles.count) {
            model.send(.reorderProfile(model.profiles[drag.from].id, index: insertion))
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.endDotDrag(drag) }
        placeDots(drag, includingDragged: true)
        Motion.sidebar.set(drag.dots[drag.from], "transform.scale", to: NSNumber(value: 1), spring: .selection)
        CATransaction.commit()
        return true
    }

    /// Whether `point` (bar coordinates) is outside the window's content.
    private func outsideWindow(_ point: NSPoint) -> Bool {
        guard let content = window?.contentView else { return false }
        return !content.bounds.contains(content.convert(point, from: self))
    }

    private func beginDotDrag(_ index: Int, at start: NSPoint) {
        guard let host = layer else { return }
        let rects = slotRects()
        let strip = strip
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let container = CALayer()
        container.frame = bounds
        let dots = model.profiles.enumerated().map { offset, profile in
            let active = profile.id == model.activeProfileID
            let slot = rects[offset]
            // The current space's dot carries its chip (the bar's own chip hides while the dots move).
            let image = performWithTheme {
                Self.render(slot.size, scale: scale) { rect in
                    if active {
                        Palette.selectionFill.setFill()
                        let chip = ProfileBarLogic.chipRect(slot: rect, inset: Metrics.space1)
                        NSBezierPath(roundedRect: chip, xRadius: SidebarStyle.rowCornerRadius, yRadius: SidebarStyle.rowCornerRadius).fill()
                    }
                    draw(profile: profile, in: rect, active: active, hovered: false, compact: strip.compact && !active)
                }
            }
            let dot = CALayer()
            dot.contentsScale = scale
            dot.contents = image
            dot.frame = slot
            container.addSublayer(dot)
            return dot
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.addSublayer(container)
        marks.isHidden = true
        indicator.isHidden = true
        CATransaction.commit()
        let drag = ProfileBarDotDrag(from: index, grab: start.x - rects[index].midX, container: container, dots: dots)
        dotDrag = drag
        setHovered(nil)
        setPressed(nil)
        // The dragged dot lifts.
        dots[index].zPosition = 1
        Motion.sidebar.set(dots[index], "transform.scale", to: NSNumber(value: 1.15), spring: .selection)
    }

    /// Springs every dot but the dragged one (and it too when `includingDragged`) to its slot in the drop's order.
    private func placeDots(_ drag: ProfileBarDotDrag, includingDragged: Bool) {
        let rects = slotRects()
        let order = ProfileBarDotDrag.order(Array(drag.dots.indices), moving: drag.from, to: drag.target)
        for (position, index) in order.enumerated() where (includingDragged || index != drag.from) && rects.indices.contains(position) {
            Motion.sidebar.set(drag.dots[index], "position", to: NSValue(point: CGPoint(x: rects[position].midX, y: bounds.midY)), spring: .selection)
        }
    }

    /// The dots landed: the bar draws its marks (in the new order once the reorder applied) and its chip again.
    private func endDotDrag(_ drag: ProfileBarDotDrag) {
        guard dotDrag === drag else { return }
        dotDrag = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drag.container.removeFromSuperlayer()
        marks.isHidden = false
        CATransaction.commit()
        refresh()
    }

    /// `draw` rendered at `scale` into an image `size` big, in flipped coordinates like the bar's.
    private static func render(_ size: NSSize, scale: CGFloat, _ draw: (NSRect) -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// Whether `point` (bar coordinates) is over the footer band the bar sits in (its superview,
    /// the sidebar's footer row), with a little slack above and below.
    func footerBand(contains point: NSPoint) -> Bool {
        let band = superview.map { convert($0.bounds, from: $0) }.map { $0.union(bounds) } ?? bounds
        return band.insetBy(dx: 0, dy: -Metrics.space2).contains(point)
    }
}
