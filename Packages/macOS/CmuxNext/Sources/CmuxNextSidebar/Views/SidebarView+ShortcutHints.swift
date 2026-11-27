public import AppKit
import CmuxNextDesign

extension SidebarViewComponents {
    /// Every fully visible sidebar destination in sidebar coordinates, keyed by
    /// the ``SidebarItem`` that Cmd-digit selects (``SidebarItemOrder/number(for:_:)``).
    ///
    /// The shortcut-hint overlay asks the item order which digit reaches each
    /// key, so a chip shows wherever a shortcut lands: workspace rows, a
    /// collapsed group, item rows, and top items (Home, the App Store) drawn in
    /// a band or in a document block among the rows. No slot is hard-coded.
    ///
    /// Each frame is the row's content: its drawn fill, ending on the trailing mark column's right edge
    /// (the shared slot inside the fill), so a chip right-aligned in it (with no further inset) ends on one x for
    /// every row kind. A band or block row's view runs `horizontalInset` past its pill on each side; its bounds put
    /// Home's and the pinned rows' chips at another x than the workspace rows' (Lawrence 2026-10-29: "alignmnet
    /// here is generally pretty bad"). An icon tile's frame is its pill, where its chip centers.
    public var shortcutHintItemFrames: [SidebarItem: CGRect] {
        guard !isHiddenOrHasHiddenAncestor, bounds.width > 1 else { return [:] }
        var result: [SidebarItem: CGRect] = [:]
        let viewport = scrollViewFrameForHints
        for (key, row) in list.rowViews where row.alphaValue > 0.9 {
            let item: SidebarItem
            switch key {
            case let .workspace(id): item = .workspace(id)
            case let .group(id): item = .group(id)
            case let .item(id): item = .topItem(LayoutItemID(id))
            default: continue
            }
            let rect = row.convert(row.bounds, to: self)
            guard viewport.contains(rect) else { continue }
            result[item] = Self.hintContent(ofFill: rect)
        }
        // Top items: the bands above and below the list, and document blocks drawn as list rows.
        for region in bandRegions + list.blockRegions where !region.isHiddenOrHasHiddenAncestor && region.alphaValue > 0.5 {
            for (id, view) in region.itemViews where !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0.5 {
                // Fully shown only: a tile scrolled half out of its band or the list gets no chip. A band row runs
                // past the sidebar's edge by the row trim (`rowEdgeGap`), which is not scrolled out.
                let visible = view.visibleRect, overhang = max(0, -SidebarStyle.rowTrailingTrim)
                guard visible.width >= view.bounds.width - overhang - 0.5, visible.height >= view.bounds.height - 0.5, view.bounds.width > 1 else { continue }
                let pill = view.convert(view.pill.frame, to: self)
                result[.topItem(id)] = view.style.isIconOnly ? pill : Self.hintContent(ofFill: pill)
            }
        }
        return result
    }

    private var scrollViewFrameForHints: CGRect { list.convert(list.visibleRect, to: self) }

    /// A row's content from its drawn fill: the fill up to the trailing mark column's right edge
    /// (`SidebarStyle.trailingColumnCenterX`), where every trailing mark and the hint chip end.
    private static func hintContent(ofFill fill: CGRect) -> CGRect {
        var content = fill
        content.size.width = max(0, SidebarStyle.trailingColumnStart(rowWidth: fill.width) + SidebarStyle.trailingSlotSide)
        return content
    }

    /// Space-switcher slots in sidebar coordinates, in the space selection order.
    public var shortcutHintSpaceFrames: [CGRect] {
        // No hints over a strip faded out (`sidebar.spacesVisibility` hover).
        guard !isHiddenOrHasHiddenAncestor, !profileBar.isHidden, profileBar.alphaValue > 0.5, bounds.width > 1 else { return [] }
        return profileBar.slotRects().prefix(model.profiles.count).map { profileBar.convert($0, to: self) }
    }
}
