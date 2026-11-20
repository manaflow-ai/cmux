import AppKit

/// Up and Down walk every visible row of the sidebar in visual order
/// (sidebar-sections.md 6, cx-qno.10): the items above the list, the
/// "+ New workspace" row while the row restyle shows it (`SidebarNewWorkspaceRowView`), the
/// list's stops (group headers, disclosures and workspace rows, `SidebarGroupKeys`),
/// then the items below it and the footer. Past the list's first or last
/// stop, keyboard focus moves to the nearest item, and from an item back to
/// the list's nearest stop.
@MainActor enum SidebarArrowWalk {
    /// True while the walk moves focus to an item: arrows reach items
    /// without Full Keyboard Access, which Tab still needs.
    private(set) static var isMovingFocus = false

    /// One stop of the walk: an item row, the New workspace row, or the workspace list.
    private enum Stop {
        case item(SidebarItemRowView)
        case newWorkspaceRow(SidebarNewWorkspaceRowView)
        case list
    }

    /// Up from the list's first stop or Down from its last: focuses the
    /// nearest item that way (the New workspace row first, going up). False when there is none.
    static func leave(_ list: SidebarListView, up: Bool) -> Bool {
        guard let sidebar = sidebar(of: list) else { return false }
        if up, let row = newWorkspaceRow(in: sidebar), focus(row) { return true }
        let (above, below) = items(in: sidebar)
        guard let item = up ? above.last : below.first, focus(item) else { return false }
        return true
    }

    /// Makes `view` (an item row or the New workspace row) first responder and scrolls it into its band.
    private static func focus(_ view: NSView) -> Bool {
        isMovingFocus = true
        defer { isMovingFocus = false }
        guard view.window?.makeFirstResponder(view) == true else { return false }
        view.scrollToVisible(view.bounds)
        return true
    }

    /// Up or Down from a focused item: the next stop that way (none at
    /// either end of the sidebar). False for any other key.
    static func step(from item: SidebarItemRowView, _ event: NSEvent) -> Bool {
        step(from: item, event) { if case let .item(view) = $0 { view === item } else { false } }
    }

    /// Up or Down from the focused New workspace row: the item above it, or the list's first stop
    /// (the first item below when the list has none). False for any other key.
    static func step(from row: SidebarNewWorkspaceRowView, _ event: NSEvent) -> Bool {
        step(from: row, event) { if case let .newWorkspaceRow(view) = $0 { view === row } else { false } }
    }

    private static func step(from view: NSView, _ event: NSEvent, isCurrent: (Stop) -> Bool) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard flags.isEmpty, event.specialKey == .upArrow || event.specialKey == .downArrow,
              let sidebar = sidebar(of: view) else { return false }
        let up = event.specialKey == .upArrow
        let (above, below) = items(in: sidebar)
        let list = sidebar.list
        let row = newWorkspaceRow(in: sidebar).map { [Stop.newWorkspaceRow($0)] } ?? []
        let stops = above.map(Stop.item) + row + (SidebarGroupKeys(list: list).stops.isEmpty ? [] : [Stop.list]) + below.map(Stop.item)
        guard let index = stops.firstIndex(where: isCurrent) else { return false }
        // At either end the key stops there, as at the list's ends: no beep.
        guard stops.indices.contains(index + (up ? -1 : 1)) else { return true }
        switch stops[index + (up ? -1 : 1)] {
        case let .item(next):
            _ = focus(next)
        case let .newWorkspaceRow(next):
            _ = focus(next)
        case .list:
            // Entering the list goes to its nearest stop, as an arrow inside it does.
            view.window?.makeFirstResponder(list)
            let keys = SidebarGroupKeys(list: list)
            if let stop = up ? keys.stops.last : keys.stops.first { keys.focus(stop) }
        }
        return true
    }

    /// The New workspace row while it shows (the row restyle), else nil.
    private static func newWorkspaceRow(in sidebar: SidebarView) -> SidebarNewWorkspaceRowView? {
        sidebar.newWorkspaceRowView.flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : $0 }
    }

    /// The focusable item rows above and below the list, each in visual
    /// order (top to bottom, then leading to trailing).
    private static func items(in sidebar: SidebarView) -> (above: [SidebarItemRowView], below: [SidebarItemRowView]) {
        func ordered(_ regions: [SidebarRegionView]) -> [SidebarItemRowView] {
            let positioned: [(view: SidebarItemRowView, frame: NSRect)] = regions.flatMap { region in
                region.itemViews.values.filter { !$0.isHiddenOrHasHiddenAncestor }.map {
                    (view: $0, frame: region.convert($0.frame, to: nil))
                }
            }
            let sorted: [(view: SidebarItemRowView, frame: NSRect)] = positioned.sorted {
                (lhs: (view: SidebarItemRowView, frame: NSRect), rhs: (view: SidebarItemRowView, frame: NSRect)) -> Bool in
                lhs.frame.maxY != rhs.frame.maxY ? lhs.frame.maxY > rhs.frame.maxY : lhs.frame.minX < rhs.frame.minX
            }
            return sorted.map(\.view)
        }
        return (ordered([sidebar.aboveRegion]), ordered([sidebar.belowRegion, sidebar.footerRegion]))
    }

    private static func sidebar(of view: NSView) -> SidebarView? {
        sequence(first: view.superview, next: { $0?.superview }).lazy.compactMap { $0 as? SidebarView }.first
    }
}
