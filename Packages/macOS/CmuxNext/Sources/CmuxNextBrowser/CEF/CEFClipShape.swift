import AppKit

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

    /// `bounds` intersected with every rounded rect, or nil when no rounded
    /// corner cuts into `bounds` (the page is a plain rectangle and the
    /// fork's visible-rect clip is enough).
    static func path(bounds: CGRect, clips: [RoundedRect]) -> CGPath? {
        guard !bounds.isEmpty else { return nil }
        let cutting = clips.filter { cutsCorner(of: $0, into: bounds) }
        guard !cutting.isEmpty else { return nil }
        var shape = CGPath(rect: bounds, transform: nil)
        for clip in cutting {
            let radius = min(clip.radius, min(clip.rect.width, clip.rect.height) / 2)
            let rounded = CGPath(roundedRect: clip.rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            shape = shape.intersection(rounded)
        }
        return shape
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

    /// Radius of a window's own corners: AppKit's value when it reports one
    /// (`_cornerRadius`, private, read only when present), else the macOS 26
    /// titled-window default. Zero in fullscreen and for borderless windows.
    @MainActor
    static func windowCornerRadius(_ window: NSWindow) -> CGFloat {
        if window.styleMask.contains(.fullScreen) || !window.styleMask.contains(.titled) { return 0 }
        let selector = NSSelectorFromString("_cornerRadius")
        if window.responds(to: selector), let value = window.value(forKey: "_cornerRadius") as? NSNumber {
            return CGFloat(value.doubleValue)
        }
        return fallbackWindowCornerRadius
    }

    static let fallbackWindowCornerRadius: CGFloat = 16

    /// Rounded clips around `view`: every ancestor whose layer clips with a
    /// corner radius (the layout's pane clip), then the window's corners.
    /// Rects are in `view`'s coordinates.
    @MainActor
    static func clips(around view: NSView) -> [RoundedRect] {
        var result: [RoundedRect] = []
        var ancestor = view.superview
        while let current = ancestor {
            if let layer = current.layer, layer.masksToBounds, layer.cornerRadius > 0 {
                result.append(RoundedRect(rect: view.convert(current.bounds, from: current), radius: layer.cornerRadius))
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
