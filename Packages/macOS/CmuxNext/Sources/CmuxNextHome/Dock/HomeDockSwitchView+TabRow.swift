public import AppKit
public import CmuxNextDesign

/// The shown view's tools in the pane's tab row (``HomeDockSwitchView/rowTools``; Leo 2026-10-20: the
/// Chief's pane gets a top-right area like a workspace's): at the row's trailing end, left of the
/// pane's own toolbar, while the pane offers the row; the shown view sits under the row then.
extension HomeDockSwitchView: PaneTabRowSharing {
    public var tabRowToolsWidth: CGFloat? { reportedToolsWidth > 0 ? reportedToolsWidth : nil }

    public func setTabRow(height: CGFloat, trailingInset: CGFloat) {
        guard height != tabRow.height || trailingInset != tabRow.trailingInset else { return }
        tabRow = (height, trailingInset)
        needsLayout = true
    }

    /// The shown view's tools' width now, a gap before them included; 0 with none or with
    /// `ChromeTunables.tabRowTools` off.
    var shownToolsWidth: CGFloat {
        guard ChromeTunables.tabRowTools.value, let tools = rowTools[mode] else { return 0 }
        return ceil(max(tools.intrinsicContentSize.width, tools.fittingSize.width)) + Metrics.space2
    }

    /// Reports a change in the tools' width, places the shown view's tools in the row and hides the
    /// others; returns the points of the top the row covers (0: the tools are not in it).
    func layoutRowTools() -> CGFloat {
        let width = shownToolsWidth
        if width > 0 { tabRowToolsNeed = width }
        if width != reportedToolsWidth {
            reportedToolsWidth = width
            onTabRowToolsChange?()
        }
        let cover = width > 0 ? tabRow.height : 0
        setTabRowCover(cover)
        for (mode, tools) in rowTools {
            if tools.superview !== self { addSubview(tools) }
            tools.isHidden = mode != self.mode || cover <= 0
            guard !tools.isHidden else { continue }
            let toolsWidth = width - Metrics.space2
            tools.frame = NSRect(x: bounds.width - tabRow.trailingInset - toolsWidth, y: isFlipped ? 0 : bounds.height - cover,
                                 width: toolsWidth, height: cover)
        }
        return cover
    }
}

/// The shown view's tools' rows in the pane's more menu (the Chief's, over Messages): the pane keeps
/// one ⋮ (Lawrence 2026-10-22).
extension HomeDockSwitchView: PaneMoreMenuContributing {
    public func paneMoreMenuItems() -> [NSMenuItem] { (rowTools[mode] as? PaneMoreMenuContributing)?.paneMoreMenuItems() ?? [] }
}
