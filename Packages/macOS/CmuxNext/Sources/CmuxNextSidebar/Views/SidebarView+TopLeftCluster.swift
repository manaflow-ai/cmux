import AppKit
import CmuxNextDesign

// `sidebar.topLeftCluster` (``SidebarTopLeftCluster``): the sidebar's top-left corner group, the +, the header,
// the list's first row and the first horizontal tab (Leo 2026-11-05: "There's just this extremely awful corner
// area where it's like, okay, you have this plus symbol, and then you have the divider, and then you have like
// the workspaces, and then you have the top horizontal tab"). `standard` leaves today's layout untouched;
// compact density always draws `standard`.
//
// The alignment every other look shares: the + takes the footer Search's frame rule (its side, its column from
// `SidebarFooterBand.searchPlacement`, the same pixel snap) and Search's glyph size, so the two glyphs sit on one
// center x and fill the same box the same way. Before, the + was a header-height box ending `space3` from the
// edge with a `smallIconSize` glyph, and Search a row-height box on the trailing column with an `iconSize` glyph
// (Leo: "that like magnifying glass, it isn't aligned. And the new workspace, like those two things, like
// they're just not aligned").
extension SidebarView {
    /// The corner look that draws now: the setting, except at compact density, which keeps `standard`.
    var topLeftCluster: SidebarTopLeftCluster {
        design.sidebarSections.topLeftCluster.effective(compact: design.sidebarSections.density == .compact)
    }

    /// The room the `listRow` look's New Workspace row takes under the header (the row and the rows' gap); 0 otherwise.
    var topLeftListRowSpace: CGFloat {
        topLeftCluster == .listRow ? SidebarDensityTokens.rowHeight + Metrics.space1 : 0
    }

    /// The `tabLead` look: the container puts ``tabLeadButton`` in the first tab strip's leading slot
    /// (SidebarContainerView+TabLead) and the sidebar header shows no +.
    var showsTabLeadNewWorkspace: Bool { topLeftCluster == .tabLead }

    /// The corner look or the density changed: this view and its container (which places the tab strip's +) lay out again.
    func topLeftClusterChanged() {
        needsLayout = true
        var ancestor = superview
        while let view = ancestor {
            if let container = view as? SidebarContainerView {
                container.needsLayout = true
                return
            }
            ancestor = view.superview
        }
    }

    /// The square the + takes on Search's column: Search's side and x (``SidebarFooterBand/searchPlacement``),
    /// centered on `midY`, snapped to the backing pixel the way Search is.
    func plusFrameOnSearchColumn(midY: CGFloat) -> NSRect {
        let side = SidebarFooterBand.searchButtonSide
        let x = SidebarFooterBand.searchPlacement(sidebarWidth: bounds.width, side: side, itemsMaxX: nil).x
        let scale = window?.backingScaleFactor ?? 2
        return NSRect(x: (x * scale).rounded() / scale, y: ((midY - side / 2) * scale).rounded() / scale, width: side, height: side)
    }

    /// Lays the corner look out after the standard header pass placed the + (`standard`, the frame passed in).
    /// Returns the frame the header's Priority bell sits before: the leftmost control the look put on the
    /// header's trailing slots.
    func layoutTopLeftCluster(rowMidY: CGFloat, standardPlusFrame: NSRect) -> NSRect {
        let look = topLeftCluster
        let aligned = look.alignsWithSearch
        if aligned != plusTakesSearchSize {
            plusTakesSearchSize = aligned
            newButton.pointSize = aligned ? { Metrics.iconSize } : { Metrics.smallIconSize }
        }
        if look == .listRow { installNewWorkspaceRow() }
        newWorkspaceRowIfBuilt?.isHidden = look != .listRow
        newButton.isHidden = look == .listRow || look == .tabLead
        guard aligned else { return standardPlusFrame }
        // The chooser chevron would run past Search's column into the resize edge: these looks keep its menu on
        // the +'s right-click only, as with `sidebar.showNewWorkspaceChooser` off (the default).
        newWorkspaceOptionsButton.isHidden = true
        newButton.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        let plus = plusFrameOnSearchColumn(midY: rowMidY)
        newButton.frame = plus
        switch look {
        case .headerRow where design.sidebarSections.showSearchButton && !design.sidebarSections.noFade:
            // Search moves up beside the +, one slot before it on the same line and box: one header row, one grid.
            // The footer pass then leaves it here (``searchLivesInHeader``); `sidebar.showSearchButton` still hides it.
            searchButton.frame = plus.offsetBy(dx: -(plus.width + Metrics.space1), dy: 0)
            return searchButton.frame
        case .listRow:
            let height = SidebarDensityTokens.rowHeight
            // The rows' fill: the list's leading inset, and the rows' gap from the trailing edge.
            let x = SidebarStyle.horizontalInset
            newWorkspaceRowIfBuilt?.frame = NSRect(x: x, y: titlebarHeight, width: max(0, bounds.width - x - SidebarStyle.rowEdgeGap),
                                                   height: height)
            return plus
        default:
            return plus
        }
    }

    /// Whether the footer leaves Search to the header (`headerRow`): the footer neither places it nor reserves its line.
    var searchLivesInHeader: Bool { topLeftCluster == .headerRow }

    func buildTopLeftCluster() {
        tabLeadButton.onPress = { [weak self] in self?.model.send(.newWorkspace(machine: nil, group: nil)) }
        tabLeadButton.menuProvider = { [weak self] in self?.list.contextMenuProvider?(.background) }
        tabLeadButton.setAccessibilityIdentifier("cmux.sidebar.newWorkspace.tabLead")
        tabLeadButton.isHidden = true
    }

    private func installNewWorkspaceRow() {
        guard newWorkspaceRowIfBuilt == nil else { return }
        let row = SidebarNewWorkspaceRow()
        row.onPress = { [weak self] in self?.model.send(.newWorkspace(machine: nil, group: nil)) }
        row.menuProvider = { [weak self] in self?.list.contextMenuProvider?(.background) }
        row.onMenuOpenChange = { [weak self] open in self?.chromeMenuOpenChanged(open) }
        row.alphaValue = newButton.alphaValue
        addSubview(row)
        newWorkspaceRowIfBuilt = row
    }
}
