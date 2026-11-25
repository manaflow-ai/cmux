import AppKit
import CmuxNextSettings
import CmuxNextTabs

extension PaneContentView {
    /// The strip, or the vertical list in its place (Leo 2026-10-20): vertical tabs hide the strip.
    func showStrip(hidden: Bool, vertical: PaneVerticalTabs?) {
        let hides = hidden || vertical != nil
        if hidesStrip != hides { hidesStrip = hides }
        if verticalTabs != vertical { verticalTabs = vertical }
    }

    /// Shows, updates or hides the vertical list. The strip hides through `hidesStrip`
    /// (``PaneController/apply(_:force:)``), so the pane's header goes with it.
    func applyVerticalTabs() {
        if let wanted = verticalTabs {
            (verticalList ?? makeVerticalList()).show(collapsed: wanted.collapsed, expandsOnHover: wanted.expandsOnHover)
        } else {
            verticalList?.isHidden = true
        }
        needsLayout = true
    }

    private func makeVerticalList() -> VerticalTabListView {
        let list = VerticalTabListView(following: stripView)
        list.onHoverExpansionChange = { [weak self] _ in self?.needsLayout = true }
        // Above the content: an expanded-on-hover list draws over the page beside it.
        addSubview(list, positioned: .above, relativeTo: contentHost)
        verticalList = list
        return list
    }

    /// The width the vertical list takes from the content on the pane's leading edge (``VerticalTabListView/layOut(onLeadingEdgeOf:)``).
    func layoutVerticalList() -> CGFloat {
        guard verticalTabs != nil, let list = verticalList, !list.isHidden else { return 0 }
        return list.layOut(onLeadingEdgeOf: bounds)
    }
}
