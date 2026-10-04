public import CoreGraphics

/// The pure visibility rules for an agent cursor target (a browser tab).
/// No AppKit: the App builds an `AgentCursorVisibilitySnapshot` from the live
/// models and asks here. Shared vectors: schemas/agent-cursor-visibility.
public nonisolated enum AgentCursorVisibilityResolver {
    /// Thickness of an edge anchor (column edge, window edge).
    public static let edgeThickness: CGFloat = 4

    public static func resolve(target: String, in snapshot: AgentCursorVisibilitySnapshot) -> AgentCursorVisibility {
        guard let tab = snapshot.tab else { return .notDrawn(.tabClosed) }
        // The front-most window that shows the workspace, else one that lists it.
        guard let window = snapshot.windows.first(where: { $0.shownWorkspace == tab.workspace })
            ?? snapshot.windows.first(where: { $0.listedWorkspaces.contains(tab.workspace) }) else {
            return .notDrawn(.notInAnyWindow)
        }
        // CURSOR-SCREENS: another display draws; minimized or another Space does not.
        if window.minimized { return .notDrawn(.minimized) }
        if !window.onActiveSpace { return .notDrawn(.otherSpace) }
        guard window.shownWorkspace == tab.workspace else { return workspaceAnchor(tab.workspace, in: window) }
        guard let pane = window.panes.first(where: { $0.id == tab.pane }),
              let frame = pane.frame?.cgRect, let clip = pane.clip?.cgRect else {
            // The pane is not on the active screen of the workspace.
            return .hidden(window: window.id, anchor: .windowEdge, rect: windowEdge(window.overlay.cgRect))
        }
        guard shows(frame, in: clip) else { return columnEdge(of: frame, clip: clip, window: window.id) }
        guard pane.selectedTab == target, let page = pane.page else {
            // A background tab (or a selected page not laid out yet): its chip.
            return chipAnchor(target, pane: pane, clip: clip, window: window.id)
        }
        let viewport = page.viewport.cgRect
        guard shows(viewport, in: clip) else { return columnEdge(of: viewport, clip: clip, window: window.id) }
        return .visible(window: window.id, viewport: viewport, clip: viewport.intersection(clip), zoom: page.zoom)
    }

    /// Another workspace of the window: its sidebar row, else the window edge.
    static func workspaceAnchor(_ workspace: String, in window: AgentCursorVisibilitySnapshot.Window) -> AgentCursorVisibility {
        if !window.sidebarHidden, let row = window.sidebarRows[workspace] {
            return .hidden(window: window.id, anchor: .workspaceRow, rect: row.cgRect)
        }
        return .hidden(window: window.id, anchor: .windowEdge, rect: windowEdge(window.overlay.cgRect))
    }

    static func chipAnchor(_ target: String, pane: AgentCursorVisibilitySnapshot.Pane, clip: CGRect, window: String) -> AgentCursorVisibility {
        if let chip = pane.chips[target]?.cgRect, shows(chip, in: clip) {
            return .hidden(window: window, anchor: .tabChip, rect: chip.intersection(clip))
        }
        if let strip = pane.strip?.cgRect, shows(strip, in: clip) {
            return .hidden(window: window, anchor: .tabStrip, rect: strip.intersection(clip))
        }
        let frame = pane.frame?.cgRect ?? clip
        return .hidden(window: window, anchor: .tabStrip, rect: frame.intersection(clip))
    }

    /// The strip edge on the side `rect` left `clip` through.
    static func columnEdge(of rect: CGRect, clip: CGRect, window: String) -> AgentCursorVisibility {
        let t = edgeThickness
        let side: AgentCursorEdge
        if rect.maxX <= clip.minX + 0.5 {
            side = .leading
        } else if rect.minX >= clip.maxX - 0.5 {
            side = .trailing
        } else if rect.maxY <= clip.minY + 0.5 {
            side = .top
        } else {
            side = .bottom
        }
        let anchor: CGRect
        switch side {
        case .leading, .trailing:
            let (minY, maxY) = overlap(rect.minY, rect.maxY, clip.minY, clip.maxY)
            anchor = CGRect(x: side == .leading ? clip.minX : clip.maxX - t, y: minY, width: t, height: maxY - minY)
        case .top, .bottom:
            let (minX, maxX) = overlap(rect.minX, rect.maxX, clip.minX, clip.maxX)
            anchor = CGRect(x: minX, y: side == .top ? clip.minY : clip.maxY - t, width: maxX - minX, height: t)
        }
        return .hidden(window: window, anchor: .columnEdge(side), rect: anchor)
    }

    /// The overlapping range of two intervals, or the second interval when they do not overlap.
    private static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> (CGFloat, CGFloat) {
        let lo = max(a0, b0), hi = min(a1, b1)
        return hi > lo ? (lo, hi) : (b0, b1)
    }

    static func windowEdge(_ overlay: CGRect) -> CGRect {
        CGRect(x: overlay.minX, y: overlay.minY, width: edgeThickness, height: overlay.height)
    }

    /// At least half a point of `rect` lies in `clip` on both axes.
    static func shows(_ rect: CGRect, in clip: CGRect) -> Bool {
        let overlap = rect.intersection(clip)
        return !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
    }

    /// `rect` moved into `bounds` so the overlay plane can draw it: the part
    /// inside when there is one, else a zero-thickness rect on the nearest
    /// edge (a sidebar row sits left of the layout root, so its indicator
    /// draws on the content's leading edge at the row's height).
    public static func drawableRect(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        let inside = rect.intersection(bounds)
        if !inside.isNull, inside.width > 0, inside.height > 0 { return inside }
        func project(_ lo: CGFloat, _ hi: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> (CGFloat, CGFloat) {
            if hi <= b0 { return (b0, b0) }
            if lo >= b1 { return (b1, b1) }
            return (max(lo, b0), min(hi, b1))
        }
        let (x0, x1) = project(rect.minX, rect.maxX, bounds.minX, bounds.maxX)
        let (y0, y1) = project(rect.minY, rect.maxY, bounds.minY, bounds.maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
