import CmuxNextSidebar

// Cmd-Ctrl-] / Cmd-Ctrl-[ (R119): next / previous item in the sidebar section
// that holds the current item; in the workspaces list (or with no current
// item) the caller steps workspaces as before.
extension SidebarBridge {
    /// The item the window shows (Home, a pinned workspace), else the item
    /// the last step reached while the shown workspace has not changed since.
    func currentLayoutItem(shownWorkspace: String?) -> LayoutItemID? {
        let layout = model.layout
        for section in layout.sections {
            for item in section.items {
                if model.itemInfo[item.id]?.isActive == true { return item.id }
                if let shownWorkspace, item.ref.kind == LayoutItemRef.workspaceKind, item.ref.value == shownWorkspace { return item.id }
            }
        }
        if let cursor = sectionStepCursor, cursor.workspace == shownWorkspace, layout.item(cursor.item) != nil { return cursor.item }
        return nil
    }

    /// Steps `offset` items in the current item's section and runs that item
    /// as a click does. Returns false when there is no item step (the
    /// caller then steps workspaces).
    func stepSectionItem(by offset: Int, shownWorkspace: () -> String?) -> Bool {
        guard let current = currentLayoutItem(shownWorkspace: shownWorkspace()),
              let target = SidebarSectionStepping.step(from: current, by: offset, in: model.layout, skip: { item in
                  let info = model.itemInfo[item.id]
                  return info?.isHidden == true || info?.isMissing == true || model.suppressedApps.contains(item.owningAppID ?? "")
              }) else { return false }
        activateLayoutItem(target)
        sectionStepCursor = (target, shownWorkspace())
        return true
    }
}
