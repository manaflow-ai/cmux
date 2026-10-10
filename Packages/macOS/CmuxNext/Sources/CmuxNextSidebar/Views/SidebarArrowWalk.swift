import AppKit

/// Up and Down walk every visible row of the sidebar in visual order
/// (sidebar-sections.md 6, cx-qno.10): the items above the list, the
/// list's stops (group headers and workspace rows, `SidebarGroupKeys`),
/// then the items below it and the footer. Past the list's first or last
/// stop, keyboard focus moves to the nearest item, and from an item back to
/// the list's nearest stop.
@MainActor enum SidebarArrowWalk {
    /// True while the walk moves focus to an item: arrows reach items
    /// without Full Keyboard Access, which Tab still needs.
    private(set) static var isMovingFocus = false

    /// One stop of the walk: an item row, or the workspace list.
    private enum Stop {
        case item(SidebarItemRowView)
        case list
    }

    /// Up from the list's first stop or Down from its last: focuses the
    /// nearest item that way. False when there is none.
    static func leave(_ list: SidebarListView, up: Bool) -> Bool {
        guard let sidebar = sidebar(of: list) else { return false }
        let (above, below) = items(in: sidebar)
        guard let item = up ? above.last : below.first, focus(item) else { return false }
        return true
    }

    /// Makes `item` first responder and scrolls it into its band.
    private static func focus(_ item: SidebarItemRowView) -> Bool {
        isMovingFocus = true
        defer { isMovingFocus = false }
        guard item.window?.makeFirstResponder(item) == true else { return false }
        item.scrollToVisible(item.bounds)
        return true
    }

    /// Up or Down from a focused item: the next stop that way. False for
    /// any other key, or at either end of the sidebar.
    static func step(from item: SidebarItemRowView, _ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard flags.isEmpty, event.specialKey == .upArrow || event.specialKey == .downArrow,
              let sidebar = sidebar(of: item) else { return false }
        let up = event.specialKey == .upArrow
        let (above, below) = items(in: sidebar)
        let list = sidebar.list
        let stops = above.map(Stop.item) + (SidebarGroupKeys(list: list).stops.isEmpty ? [] : [Stop.list]) + below.map(Stop.item)
        guard let index = stops.firstIndex(where: { if case let .item(view) = $0 { view === item } else { false } }),
              stops.indices.contains(index + (up ? -1 : 1)) else { return false }
        switch stops[index + (up ? -1 : 1)] {
        case let .item(next):
            _ = focus(next)
        case .list:
            // Entering the list goes to its nearest stop, as an arrow inside it does.
            item.window?.makeFirstResponder(list)
            let keys = SidebarGroupKeys(list: list)
            if let stop = up ? keys.stops.last : keys.stops.first { keys.focus(stop) }
        }
        return true
    }

    /// The focusable item rows above and below the list, each in visual
    /// order (top to bottom, then leading to trailing).
    private static func items(in sidebar: SidebarView) -> (above: [SidebarItemRowView], below: [SidebarItemRowView]) {
        func ordered(_ regions: [SidebarRegionView]) -> [SidebarItemRowView] {
            regions.flatMap { region in
                region.itemViews.values.filter { !$0.isHiddenOrHasHiddenAncestor }.map { ($0, region.convert($0.frame, to: nil)) }
                    .sorted { $0.1.maxY != $1.1.maxY ? $0.1.maxY > $1.1.maxY : $0.1.minX < $1.1.minX }
                    .map(\.0)
            }
        }
        return (ordered([sidebar.aboveRegion]), ordered([sidebar.belowRegion, sidebar.footerRegion]))
    }

    private static func sidebar(of view: NSView) -> SidebarView? {
        sequence(first: view.superview, next: { $0?.superview }).lazy.compactMap { $0 as? SidebarView }.first
    }
}
