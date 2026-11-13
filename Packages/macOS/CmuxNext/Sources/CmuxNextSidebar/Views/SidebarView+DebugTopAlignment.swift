public import AppKit
public import CmuxNextDesign

/// The sidebar's share of `debug.top_alignment` (`TopAlignmentProbe`): the titlebar row's +,
/// footer Search, the trailing column's x and the topmost workspace row with its leading icon and
/// trailing mark, the lines Leo named on 2026-11-07 ("the top of the sidebar with the subsequent
/// elements below (workspaces and their notification symbols, then the search icon)").
extension SidebarViewComponents: TopAlignmentReporting {
    public var topAlignmentKind: String { "sidebar" }

    public func topAlignmentFrames() -> [String: CGRect] {
        func shown(_ view: NSView) -> CGRect? {
            guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0, view.window != nil, view.bounds.width > 0 else { return nil }
            return convert(view.bounds, from: view)
        }
        var frames: [String: CGRect] = [
            "trail_x": CGRect(x: SidebarStyle.trailingColumnCenterX(sidebarWidth: bounds.width), y: 0, width: 0, height: 0),
        ]
        frames["plus"] = shown(newButton)
        frames["search"] = shown(searchButton)
        // The topmost shown workspace row (an explicit stack, as debugStatusGlyphs walks).
        var pending: [NSView] = [list]
        var top: (row: WorkspaceRowView, frame: CGRect)?
        while let view = pending.popLast() {
            guard !view.isHidden else { continue }
            if let row = view as? WorkspaceRowView {
                // Window y grows upward: the topmost row has the largest maxY.
                if let frame = shown(row), frame.height > 0,
                   top.map({ convert(frame, to: nil).maxY > convert($0.frame, to: nil).maxY }) ?? true { top = (row, frame) }
                continue
            }
            pending.append(contentsOf: view.subviews)
        }
        if let top {
            frames["row"] = top.frame
            frames["row_icon"] = shown(top.row.icon)
            frames["row_mark"] = [top.row.activity, top.row.badge, top.row.rowBadge].lazy.compactMap(shown).first
        }
        return frames
    }
}
