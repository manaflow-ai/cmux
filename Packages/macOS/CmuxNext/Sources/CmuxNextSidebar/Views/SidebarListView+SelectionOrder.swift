import AppKit

// Shift-click and Shift+Arrow ranges across pinned and listed workspaces (#27701), as classic: the range is
// every workspace drawn between its ends, pinned tiles and list rows alike, and none a collapsed section hides.

extension SidebarRegionView.Content {
    /// The open workspaces this content's tiles name, in drawn order. A collapsed section draws none.
    var workspaceOrder: [WorkspaceID] {
        sections.filter { !collapsed.contains($0.id) }.flatMap(\.items).compactMap { item in
            guard let info = infos[item.id], !info.isHidden, !info.isMissing else { return nil }
            return info.workspace
        }
    }
}

extension SidebarListViewComponents {
    /// The workspaces a selection range runs over, in drawn order: the tiles pinned above the list
    /// (`leadingSelectionOrder`), then the list's rows, each block's pinned tiles where the block draws.
    /// A workspace drawn twice counts at its first place.
    var selectionOrder: [WorkspaceID] {
        var seen = Set<WorkspaceID>(), order: [WorkspaceID] = []
        func add(_ id: WorkspaceID) { if seen.insert(id).inserted { order.append(id) } }
        leadingSelectionOrder().forEach(add)
        for row in displayed.rows {
            switch row.key {
            case let .workspace(id): add(id)
            case let .block(id): blockContent(id, includeGap: false)?.workspaceOrder.forEach(add)
            default: continue
            }
        }
        return order
    }

    /// A Shift-, Cmd- or Cmd-Shift-click on workspace `id`, from its row or its pinned tile, as classic:
    /// Shift selects the drawn range from the anchor, Cmd toggles `id`, both add the range. False for
    /// any other click, which shows the workspace.
    func modifierSelect(_ id: WorkspaceID, flags: NSEvent.ModifierFlags) -> Bool {
        if flags.contains(.shift) {
            model.extendSelection(to: id, visibleOrder: selectionOrder, adding: flags.contains(.command))
        } else if flags.contains(.command) {
            model.toggleSelection(id)
        } else {
            return false
        }
        return true
    }
}
