/// `sidebar.priorityView.enabled` and `sidebar.priorityView.shown` in cmux.json: the Priority view
/// at the top of the sidebar (every agent chat, the ones that need you first). `enabled` is the
/// App Store item's switch, off by default; `shown` is the titlebar bell's state while it is on.
/// Their paths and defaults are generated from schemas/settings/source/sidebar.json
/// (`SidebarSectionsSetting.parse` reads them).
public nonisolated struct SidebarPriorityViewSetting {
    public nonisolated init() {}
}
