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

    /// `bounds` intersected with every clip that cuts into it (a rounded
    /// corner, or a square clip that does not hold all of `bounds`), or nil
    /// when none does (the page is a plain rectangle and the fork's
    /// visible-rect clip is enough). A page clipped away entirely gets an
    /// empty shape, so it shows nowhere.
    static func path(bounds: CGRect, clips: [RoundedRect]) -> CGPath? {
        guard !bounds.isEmpty else { return nil }
        let cutting = clips.filter { cutsCorner(of: $0, into: bounds) || cutsSide(of: $0, into: bounds) }
        guard !cutting.isEmpty else { return nil }
        var shape = CGPath(rect: bounds, transform: nil)
        for clip in cutting {
            guard !clip.rect.intersection(bounds).isEmpty else { return CGPath(rect: .zero, transform: nil) }
            let radius = min(clip.radius, min(clip.rect.width, clip.rect.height) / 2)
            let rounded = CGPath(roundedRect: clip.rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            shape = shape.intersection(rounded)
        }
        return shape.boundingBoxOfPath.isEmpty ? CGPath(rect: .zero, transform: nil) : shape
    }

    /// Whether `path` shows nothing of the page: a page clipped away entirely.
    static func showsNothing(_ path: CGPath?) -> Bool {
        path?.boundingBoxOfPath.isEmpty == true
    }

    /// Whether a square `clip` leaves part of `bounds` out: the column strip's
    /// clip on a pane that scrolled under a docked column or past the strip's
    /// edge. The page is a child window, so this layer mask never reaches it
    /// and the fork's visible-rect clip does not see masks.
    static func cutsSide(of clip: RoundedRect, into bounds: CGRect) -> Bool {
        clip.radius <= 0.01 && !clip.rect.insetBy(dx: -0.5, dy: -0.5).contains(bounds)
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

    /// Radius of a window's own corners (`NSWindow.frameCornerRadius`).
    @MainActor
    static func windowCornerRadius(_ window: NSWindow) -> CGFloat {
        window.frameCornerRadius
    }

    /// Clips around `view`: every ancestor whose layer clips with a corner
    /// radius (the layout's pane clip) or a plain rectangular mask (the column
    /// strip's clip, `PaneHostView.setStripClip`), then the window's corners.
    /// Rects are in `view`'s coordinates.
    @MainActor
    static func clips(around view: NSView) -> [RoundedRect] {
        var result: [RoundedRect] = []
        var ancestor = view.superview
        while let current = ancestor {
            if let layer = current.layer, layer.masksToBounds, layer.cornerRadius > 0 {
                result.append(RoundedRect(rect: view.convert(current.bounds, from: current), radius: layer.cornerRadius))
            }
            if let mask = current.layer?.mask, mask.name == CALayer.cmuxStripClipName {
                result.append(RoundedRect(rect: view.convert(mask.frame, from: current), radius: 0))
            }
            ancestor = current.superview
        }
        if let window = view.window {
            let radius = windowCornerRadius(window)
            if radius > 0 {
                let rect = view.convert(CGRect(origin: .zero, size: window.frame.size), from: nil)
                result.append(RoundedRect(rect: rect, radius: radius))
            }
        }
        return result
    }
}
