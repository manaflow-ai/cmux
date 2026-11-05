import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// The rig's drag, its frame checks and its landing (FRAME OWNER REFACTOR S2B, `SharedEdgeDuringSpringTests`).
extension SharedEdgeDuringSpringTests.Rig {
    /// A drag of `kind`, pressed where its handle shows, `moves` steps of `step` points along `axis` (window
    /// coordinates, whole points: the edge stays on the pixel grid), one display frame per move, then `still` frames
    /// with no event. In every frame it checks the shared edges, and that the dragged edge (edge `edge` of `dragged`,
    /// as the screen draws it, in view space) shows where it showed at the press plus the pointer's travel (rule D:
    /// a grab holds the edge where the person sees it, and the pointer alone moves it). With `floor` (the dragged
    /// span's minimum from its anchor, edge `anchorEdge` of `anchor`): where the pointer would put the edge nearer
    /// the anchor's rest place than that minimum, the layout clamps it there, and the edge goes from where the
    /// pointer holds it toward that place, never past it. The press itself (a frame before the first move) moves
    /// nothing. Then the
    /// release (`releaseSpeed`: the pointer's speed at it, pt/s, set as the drag samples it), unless `release` takes
    /// it over (it gets the pointer and does the release itself).
    func drag(_ kind: DividerHandleView.Kind, dragged: PaneID, anchor: PaneID = "b1", axis: SplitAxis = .horizontal,
              edge side: KeyPath<CGRect, CGFloat> = \.maxX, anchorEdge: KeyPath<CGRect, CGFloat> = \.minX, moves: Int,
              step: CGFloat, flags: NSEvent.ModifierFlags = [], still: Int = 3, floor: CGFloat? = nil,
              releaseSpeed: CGFloat? = nil, edges: [SharedEdgeDuringSpringTests.SharedEdge],
              release: ((DividerHandleView, CGPoint) throws -> Void)? = nil) throws {
        let view = try handle(kind)
        let press = try center(kind)
        let tolerance = try halfPixel
        let start = try edge(dragged, side), pressedAt = try along(axis, press)
        // The way the dragged span grows from its anchor along the axis (+1: the edge is past the anchor).
        let grows: CGFloat = try edge(dragged, side) >= (try edge(anchor, anchorEdge)) ? 1 : -1
        func expect(_ pointer: CGPoint, _ label: String) throws {
            let want = start + (try along(axis, pointer)) - pressedAt
            let shown = try edge(dragged, side)
            if let floor {
                let nearest = try restEdge(anchor, anchorEdge) + grows * floor
                if (want - nearest) * grows < 0 {
                    if (shown - want) * grows < -tolerance || (shown - nearest) * grows > tolerance {
                        misses.append("\(label): the dragged edge shows at \(Self.pt(shown)) pt, outside the pointer's \(Self.pt(want)) pt and the clamp \(Self.pt(nearest)) pt")
                    }
                    return
                }
            }
            if abs(shown - want) > tolerance {
                misses.append("\(label): the dragged edge shows at \(Self.pt(shown)) pt, the pointer put it at \(Self.pt(want)) pt")
            }
        }
        let shownBefore = try shownFrames()
        view.mouseDown(with: event(.leftMouseDown, press, flags))
        try expectUnmoved(shownBefore, "the press")
        frame(edges, "press frame")
        try expect(press, "press frame")
        var pointer = press
        for move in 1...moves {
            if axis == .horizontal { pointer.x += step } else { pointer.y += step }
            view.mouseDragged(with: event(.leftMouseDragged, pointer, flags))
            frame(edges, "drag frame \(move)")
            try expect(pointer, "drag frame \(move)")
        }
        for tick in 0..<still {
            frame(edges, "still frame \(tick + 1)")
            try expect(pointer, "still frame \(tick + 1)")
        }
        if let releaseSpeed {
            // The speed is set, not timed: no test sleeps (as DividerDragFollowsPointerTests does).
            try screen.activeDrag?.velocity = releaseSpeed
            try screen.activeDrag?.pointer?.time = CACurrentMediaTime()
        }
        if let release { return try release(view, pointer) }
        view.mouseUp(with: event(.leftMouseUp, pointer, flags))
        root.syncWithModel()
        check(edges, "release")
    }

    /// Every pane and divider frame as the screen would draw it now (its spring's value, placed in the view and on
    /// the pixel grid as `ScreenContentView.applyPresentation` places hosts and handles).
    func shownFrames() throws -> [String: CGRect] {
        let screen = try screen, scale = screen.scale
        var shown: [String: CGRect] = [:]
        for (pane, frame) in screen.paneFrames { shown["pane \(pane)"] = screen.displayedRect(frame.rect, pane: pane).pixelEdges(scale) }
        for (kind, frame) in screen.dividerFrames {
            let placed = frame.rect.offsetBy(dx: (screen.scrolls(kind) ? screen.stripShift : 0) - screen.areaOffset(of: kind),
                                             dy: -screen.rowOffset(of: kind))
            shown["divider \(kind)"] = placed.pixelEdges(scale)
        }
        return shown
    }

    /// Records every frame that shows elsewhere than in `before` (a press, a click: nothing may move on screen).
    func expectUnmoved(_ before: [String: CGRect], _ label: String) throws {
        for (key, now) in try shownFrames() {
            guard let was = before[key] else { continue }
            if abs(now.minX - was.minX) > 0.001 || abs(now.maxX - was.maxX) > 0.001 || abs(now.minY - was.minY) > 0.001
                || abs(now.maxY - was.maxY) > 0.001 {
                misses.append("\(label) moved \(key): \(was) -> \(now)")
            }
        }
    }

    /// Display frames until nothing moves (at most 2 s of them), each checked; then the motion must have stopped:
    /// every pane and divider frame at rest on its target.
    func land(_ edges: [SharedEdgeDuringSpringTests.SharedEdge], _ label: String) {
        var frames = 0, moving = true
        while frames < 240, moving {
            frames += 1
            moving = root.advanceFrame(1.0 / 120)
            root.layoutSubtreeIfNeeded()
            ticks += 1
            check(edges, "\(label) frame \(frames)")
        }
        guard let screen = root.screenViews["s"] else { return misses.append("\(label): no screen") }
        if moving || screen.hasMotion { misses.append("\(label): still moving after \(frames) frames") }
        for (pane, frame) in screen.paneFrames where frame.rect != frame.targetRect || Self.moves(frame) {
            misses.append("\(label): \(pane) is not at rest on its target (\(frame.rect) -> \(frame.targetRect))")
        }
        for (kind, frame) in screen.dividerFrames where frame.rect != frame.targetRect || Self.moves(frame) {
            misses.append("\(label): divider \(kind) is not at rest on its target (\(frame.rect) -> \(frame.targetRect))")
        }
    }

    /// Every pane and divider frame shows `offset` along x from where it shows now and moves at `speed`, as a spring that
    /// slides the whole strip does (its shared edges stay together); then the screen presents it.
    func slideStrip(by offset: CGFloat, speed: CGFloat) throws {
        let screen = try screen
        for (pane, var frame) in screen.paneFrames {
            (frame.x.value, frame.x.velocity) = (frame.x.value + offset, speed)
            screen.paneFrames[pane] = frame
        }
        for (kind, var frame) in screen.dividerFrames {
            (frame.x.value, frame.x.velocity) = (frame.x.value + offset, speed)
            screen.dividerFrames[kind] = frame
        }
        screen.applyPresentation(force: true)
        root.layoutSubtreeIfNeeded()
    }

    /// Moves split x's line on the springs: b1's right edge, the divider and b2's left edge show `offset` from where
    /// they show now and move at `speed`, as a spring that carries the line does; then the screen presents it.
    func moveLine(by offset: CGFloat, speed: CGFloat) throws {
        let screen = try screen
        var b1 = try #require(screen.paneFrames["b1"]), b2 = try #require(screen.paneFrames["b2"])
        var divider = try #require(screen.dividerFrames[.split("x")])
        (b1.width.value, b1.width.velocity) = (b1.width.value + offset, speed)
        (divider.x.value, divider.x.velocity) = (divider.x.value + offset, speed)
        (b2.x.value, b2.x.velocity) = (b2.x.value + offset, speed)
        (b2.width.value, b2.width.velocity) = (b2.width.value - offset, -speed)
        screen.paneFrames["b1"] = b1
        screen.paneFrames["b2"] = b2
        screen.dividerFrames[.split("x")] = divider
        screen.applyPresentation(force: true)
        root.layoutSubtreeIfNeeded()
    }
}
