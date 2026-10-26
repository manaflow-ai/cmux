import AppKit

/// Everything the fork's page tracker works a page's placement out from on a
/// geometry update (`CmuxParentViewTracker -update`): the host view's rect on
/// screen, the part of it its ancestors leave visible, the clip shape's inputs
/// and the occlusion holes. Two equal values place, clip and mask the page
/// window the same way, so a page update request that finds the value the
/// fork last read has nothing to tell the fork (`CEFHostView.pagesNeedUpdate`).
nonisolated struct CEFHostGeometry: Equatable, Sendable {
    /// The host view's bounds on screen (the page window's frame).
    var screenRect: CGRect
    /// The part of the host its clipping ancestors leave visible, in window
    /// coordinates (the fork's `-visibleRectInWindow`).
    var visibleInWindow: CGRect
    /// The clip shape's inputs (`CEFClipShape.Inputs`).
    var clip: CEFClipShape.Inputs
    /// The host's own occlusion rects (find bar, prompt bar).
    var occlusion: [CGRect]
    /// The window's interactive overlays and occluders over the host
    /// (`BrowserWindowOcclusionProviding`), in the host's coordinates: a divider
    /// line moving elsewhere in the window changes nothing here.
    var windowOcclusion: [CGRect]
    var backingScale: CGFloat
    var hidden: Bool

    /// `view`'s geometry now. Reads no tracker counter: the clip memo counts
    /// the fork's reads only.
    @MainActor
    init(of view: CEFHostView) {
        let window = view.window
        let inWindow = view.convert(view.bounds, to: nil)
        screenRect = window?.convertToScreen(inWindow) ?? inWindow
        visibleInWindow = Self.visibleRectInWindow(of: view)
        clip = CEFClipShape.Inputs(around: view)
        occlusion = view.occlusionRects
        let bounds = view.bounds
        windowOcclusion = ((window as? any BrowserWindowOcclusionProviding)?.browserOcclusionRectsInWindow ?? []).compactMap { rect in
            let local = view.convert(rect, from: nil).intersection(bounds)
            return local.isNull || local.isEmpty ? nil : local
        }
        backingScale = window?.backingScaleFactor ?? 0
        hidden = view.isHiddenOrHasHiddenAncestor
    }

    /// The fork's visible rect: the view's rect in its window cut by every
    /// ancestor that clips (a clip view, the content view, a layer that masks
    /// to its bounds, a view that clips to its bounds).
    @MainActor
    private static func visibleRectInWindow(of view: NSView) -> CGRect {
        var rect = view.convert(view.bounds, to: nil)
        var ancestor = view.superview
        while let current = ancestor, !rect.isEmpty {
            let clips = current is NSClipView || current === current.window?.contentView || current.superview == nil
                || current.layer?.masksToBounds == true || current.clipsToBounds
            if clips { rect = rect.intersection(current.convert(current.bounds, to: nil)) }
            ancestor = current.superview
        }
        return rect
    }
}
