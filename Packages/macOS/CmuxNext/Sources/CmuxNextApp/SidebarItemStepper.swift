import CmuxNextSidebar

// Cmd-Ctrl-] / Cmd-Ctrl-[ (R119): next / previous item in the sidebar section
// that holds the current item; in the workspaces list (or with no current
// item) the caller steps workspaces as before. Its own type, not a
// SidebarBridge extension: the bridge type stays under the god-type budget.
@MainActor
enum SidebarItemStepper {
    /// The sidebar refs a page tab stands for: an app's page is its app item,
    /// the App Store and Settings pages their app or built-in items.
    static func refs(forPage page: InternalPageID) -> [LayoutItemRef] {
        switch page {
        case .appStore: return [.app("cmux/app-store"), .builtIn(.appStore)]
        case .coderouter: return [.app(CodeRouterPageTab.appID)]
        case .settings: return [.builtIn(.settings)]
        default:
            let prefix = AppPanePage.pageID("").rawValue
            return page.rawValue.hasPrefix(prefix) ? [.app(String(page.rawValue.dropFirst(prefix.count)))] : []
        }
    }

    /// The current item, most specific first: the item whose page the focused
    /// tab shows, an active item (Home), a pinned item of the shown workspace,
    /// else the item the last step reached while the shown workspace is unchanged.
    static func currentLayoutItem(in layout: SidebarLayoutDocument, itemInfo: [LayoutItemID: SidebarItemInfo],
                                  shownWorkspace: String?, shownPage: InternalPageID?,
                                  cursor: (item: LayoutItemID, workspace: String?)?) -> LayoutItemID? {
        let items = layout.sections.flatMap(\.items)
        if let shownPage {
            let refs = refs(forPage: shownPage)
            if let item = items.first(where: { refs.contains($0.ref) }) { return item.id }
        }
        if let item = items.first(where: { itemInfo[$0.id]?.isActive == true }) { return item.id }
        if let shownWorkspace, let item = items.first(where: { $0.ref == .workspace(shownWorkspace) }) { return item.id }
        if let cursor, cursor.workspace == shownWorkspace, layout.item(cursor.item) != nil { return cursor.item }
        return nil
    }

    /// Steps `offset` items in the current item's section and runs that item
    /// as a click does. Returns false when there is no item step (the
    /// caller then steps workspaces).
    static func step(_ bridge: SidebarBridge, by offset: Int, shownWorkspace: () -> String?, shownPage: InternalPageID?) -> Bool {
        let model = bridge.model
        guard let current = currentLayoutItem(in: model.layout, itemInfo: model.itemInfo, shownWorkspace: shownWorkspace(),
                                              shownPage: shownPage, cursor: bridge.sectionStepCursor),
              let target = SidebarSectionStepping.step(from: current, by: offset, in: model.layout, skip: { item in
                  let info = model.itemInfo[item.id]
                  return info?.isHidden == true || info?.isMissing == true || model.suppressedApps.contains(item.owningAppID ?? "")
              }) else { return false }
        bridge.activateLayoutItem(target)
        bridge.sectionStepCursor = (target, shownWorkspace())
        return true
    }
}
