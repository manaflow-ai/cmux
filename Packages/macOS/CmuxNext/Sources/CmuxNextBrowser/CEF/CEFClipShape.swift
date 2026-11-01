import AppKit
import CmuxNextDesign

/// The shape a Chromium page is limited to. The page is a child window, so
/// neither the pane's rounded clip nor the parent window's rounded corners
/// reach it; the fork masks it to this path (`-cmuxClipPath`, fork commit
/// "clip the embedded page to an embedder shape").
nonisolated enum CEFClipShape {
    /// A rounded rect in the host view's coordinates.
    struct RoundedRect: Hashable, Sendable {
        var rect: CGRect
        var radius: CGFloat
    }

    /// Everything `path` is worked out from for one view: equal inputs give
    /// the same shape, so a reader keeps the last shape while they hold
    /// (`CEFHostView.clipShape`).
    nonisolated struct Inputs: Equatable, Sendable {
        var bounds: CGRect
        var clips: [RoundedRect]
        var cutouts: [CGRect]
        /// Rounded native UI over the page (the prompt and find bars, `CEFHostView.roundedOcclusions`).
        var roundedHoles: [RoundedRect]

        init(bounds: CGRect, clips: [RoundedRect], cutouts: [CGRect] = [], roundedHoles: [RoundedRect] = []) {
            self.bounds = bounds
            self.clips = clips
            self.cutouts = cutouts
            self.roundedHoles = roundedHoles
        }

        /// `view`'s bounds, the clips and cutouts of its ancestors, and its rounded holes now.
        @MainActor
        init(around view: CEFHostView) {
            self.init(bounds: view.bounds, clips: CEFClipShape.clips(around: view), cutouts: CEFClipShape.cutouts(around: view),
                      roundedHoles: view.roundedOcclusions)
        }

        var path: CGPath? { CEFClipShape.path(bounds: bounds, clips: clips, cutouts: cutouts, roundedHoles: roundedHoles) }
    }

    /// `bounds` intersected with every clip that cuts into it (a rounded
    /// corner, or a clip that does not hold all of `bounds`), or nil
    /// when none does (the page is a plain rectangle and the fork's
    /// visible-rect clip is enough). A page clipped away entirely gets an
    /// empty shape, so it shows nowhere. `cutouts` are left out of it (a pane
    /// in front covering a corner of this one, `cutouts(around:)`), and so are
    /// `roundedHoles` with their corners: the page shows around a rounded bar's
    /// corners, where a square occlusion rect would show the pane ground. The
    /// fork routes the mouse to the parent window outside this shape too.
    static func path(bounds: CGRect, clips: [RoundedRect], cutouts: [CGRect] = [], roundedHoles: [RoundedRect] = []) -> CGPath? {
        guard !bounds.isEmpty else { return nil }
        let cutting = clips.filter { cutsCorner(of: $0, into: bounds) || cutsSide(of: $0, into: bounds) }
        let holes = cutouts.map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width > 0.01 && $0.height > 0.01 }
        let rounded = roundedHoles.filter { hole in
            let overlap = hole.rect.intersection(bounds)
            return !overlap.isNull && overlap.width > 0.01 && overlap.height > 0.01
        }
        guard !cutting.isEmpty || !holes.isEmpty || !rounded.isEmpty else { return nil }
        var shape = CGPath(rect: bounds, transform: nil)
        for clip in cutting {
            guard !clip.rect.intersection(bounds).isEmpty else { return CGPath(rect: .zero, transform: nil) }
            let radius = min(clip.radius, min(clip.rect.width, clip.rect.height) / 2)
            let rounded = CGPath(roundedRect: clip.rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            shape = shape.intersection(rounded)
        }
        for hole in holes { shape = shape.subtracting(CGPath(rect: hole, transform: nil)) }
        for hole in rounded {
            let radius = min(hole.radius, min(hole.rect.width, hole.rect.height) / 2)
            shape = shape.subtracting(CGPath(roundedRect: hole.rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        return shape.boundingBoxOfPath.isEmpty ? CGPath(rect: .zero, transform: nil) : shape
    }

    /// Whether `path` shows nothing of the page: a page clipped away entirely.
    static func showsNothing(_ path: CGPath?) -> Bool {
        path?.boundingBoxOfPath.isEmpty == true
    }

    /// Whether `clip` leaves part of `bounds` out past one of its sides: the
    /// column strip's clip on a pane that scrolled under a docked column or
    /// past the strip's edge, or the rounded main pane's straight edge across a
    /// page held at another width than it through a sidebar slide (`MainPaneCardView.contentHold`),
    /// whose corners may not reach the page. The page is a child window, so
    /// this layer mask never reaches it and the fork's visible-rect clip does
    /// not see masks.
    static func cutsSide(of clip: RoundedRect, into bounds: CGRect) -> Bool {
        !clip.rect.insetBy(dx: -0.5, dy: -0.5).contains(bounds)
    }

    /// Whether one of `clip`'s rounded corner squares overlaps `bounds`.
    static func cutsCorner(of clip: RoundedRect, into bounds: CGRect) -> Bool {
        let radius = min(clip.radius, min(clip.rect.width, clip.rect.height) / 2)
        guard radius > 0.01 else { return false }
        let r = clip.rect
        let corners = [
            CGRect(x: r.minX, y: r.minY, width: radius, height: radius),
            CGRect(x: r.maxX - radius, y: r.minY, width: radius, height: radius),
            CGRect(x: r.minX, y: r.maxY - radius, width: radius, height: radius),
            CGRect(x: r.maxX - radius, y: r.maxY - radius, width: radius, height: radius),
        ]
        return corners.contains { corner in
            let overlap = corner.intersection(bounds)
            return !overlap.isNull && overlap.width > 0.01 && overlap.height > 0.01
        }
    }

    /// The cutouts the column strip's mask carries on an ancestor
    /// (`StripClipMaskLayer.cutouts`, `PaneHostView.setStripClip`), in
    /// `view`'s coordinates.
    @MainActor
    static func cutouts(around view: NSView) -> [CGRect] {
        var result: [CGRect] = []
        var ancestor = view.superview
        while let current = ancestor {
            if let mask = current.layer?.mask, mask.name == CALayer.cmuxStripClipName,
               let rects = (mask as? StripClipMaskLayer)?.cutouts {
                result += rects.map { view.convert($0, from: current) }
            }
            ancestor = current.superview
        }
        return result
    }

    /// Radius of a window's own corners (`NSWindow.frameCornerRadius`).
    @MainActor
    static func windowCornerRadius(_ window: NSWindow) -> CGFloat {
        window.frameCornerRadius
    }

    /// Clips around `view`: every ancestor whose layer clips with a corner
    /// radius (the layout's pane clip) or a plain rectangular mask (the column
    /// strip's clip, `PaneHostView.setStripClip`), the window's corners, and
    /// the square region the square-clipping ancestors and the window leave
    /// visible, when `view` reaches past it. Rects are in `view`'s coordinates.
    ///
    /// The square region keeps a page inside its screen and window while a
    /// layout spring carries its pane past them (Leo 2026-10-20: the chat's
    /// side panel drew past the window's right edge as it opened); at rest it
    /// holds all of `view` and adds nothing.
    @MainActor
    static func clips(around view: NSView) -> [RoundedRect] {
        var result: [RoundedRect] = []
        var visible: CGRect?
        func clipVisible(to rect: CGRect) { visible = visible.map { $0.intersection(rect) } ?? rect }
        var ancestor = view.superview
        while let current = ancestor {
            if let layer = current.layer, layer.masksToBounds {
                let rect = view.convert(current.bounds, from: current)
                if layer.cornerRadius > 0 {
                    result.append(RoundedRect(rect: rect, radius: layer.cornerRadius))
                } else {
                    clipVisible(to: rect)
                }
            }
            if let mask = current.layer?.mask, mask.name == CALayer.cmuxStripClipName {
                result.append(RoundedRect(rect: view.convert(mask.frame, from: current), radius: 0))
            }
            ancestor = current.superview
        }
        if let window = view.window {
            let rect = view.convert(CGRect(origin: .zero, size: window.frame.size), from: nil)
            clipVisible(to: rect)
            let radius = windowCornerRadius(window)
            if radius > 0 {
                result.append(RoundedRect(rect: rect, radius: radius))
            }
        }
        if let visible, !visible.insetBy(dx: -0.5, dy: -0.5).contains(view.bounds) {
            result.append(RoundedRect(rect: visible.isNull ? .zero : visible, radius: 0))
        }
        return result
    }
}
