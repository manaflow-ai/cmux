/// One row nested under an agent chat tab in the sidebar: the header of its sub-sessions (a
/// disclosure with their count) or one sub-session. The list draws both with the tab row view
/// (`SidebarTabRowView`), keyed `.tab(workspace, SidebarSubsessionRowID.tabID)`.
///
/// The rows follow the chat's tab when the sidebar lists tabs (`sidebar.showWorkspaceTabs`), else
/// its workspace's row, so sub-sessions show by default. Whether a header is open is the
/// window's view state (`overrides`, keyed by the parent tab); untouched, it is open while one of
/// its sub-sessions works or waits on the person.
public nonisolated struct SidebarSubsessionRow: Hashable, Sendable {
    public nonisolated enum Kind: Hashable, Sendable {
        case header(count: Int, expanded: Bool)
        case session(SidebarSubsession)
    }

    public var parentTab: TabID
    public var kind: Kind

    public init(parentTab: TabID, kind: Kind) {
        self.parentTab = parentTab
        self.kind = kind
    }

    /// The row's id in the list.
    public var id: TabID {
        switch kind {
        case .header: SidebarSubsessionRowID(parentTab: parentTab).tabID
        case .session(let subsession): SidebarSubsessionRowID(parentTab: parentTab, session: subsession.id).tabID
        }
    }

    /// Whether `tab`'s sub-sessions show: the window's choice, else while one works or waits.
    static func isExpanded(_ tab: SidebarTab, overrides: [TabID: Bool]) -> Bool {
        overrides[tab.id] ?? tab.subsessions.contains { $0.state.isActive }
    }

    /// `tab`'s nested rows in list order: the header, then each sub-session while it is open.
    static func rows(of tab: SidebarTab, overrides: [TabID: Bool]) -> [SidebarSubsessionRow] {
        guard !tab.subsessions.isEmpty else { return [] }
        let expanded = isExpanded(tab, overrides: overrides)
        let header = SidebarSubsessionRow(parentTab: tab.id, kind: .header(count: tab.subsessions.count, expanded: expanded))
        guard expanded else { return [header] }
        return [header] + tab.subsessions.map { SidebarSubsessionRow(parentTab: tab.id, kind: .session($0)) }
    }

    /// The rows listed under workspace `ws`'s row, in order: each tab when `listsTabs`, and after an
    /// agent chat tab (or in its place, when tabs are not listed) its nested rows when `nests`.
    static func entries(_ ws: SidebarWorkspace, listsTabs: Bool, nests: Bool,
                        overrides: [TabID: Bool]) -> [(id: TabID, kind: SidebarTabKind)] {
        var entries: [(id: TabID, kind: SidebarTabKind)] = []
        for tab in ws.tabs {
            if listsTabs { entries.append((tab.id, tab.kind)) }
            guard nests else { continue }
            for row in rows(of: tab, overrides: overrides) { entries.append((row.id, .agentChat)) }
        }
        return entries
    }

    /// Every nested row's content under `ws`, shown or not, by its id.
    static func contents(_ ws: SidebarWorkspace, overrides: [TabID: Bool]) -> [TabID: SidebarSubsessionRow] {
        var contents: [TabID: SidebarSubsessionRow] = [:]
        for tab in ws.tabs where !tab.subsessions.isEmpty {
            let expanded = isExpanded(tab, overrides: overrides)
            let header = SidebarSubsessionRow(parentTab: tab.id, kind: .header(count: tab.subsessions.count, expanded: expanded))
            contents[header.id] = header
            for subsession in tab.subsessions {
                let row = SidebarSubsessionRow(parentTab: tab.id, kind: .session(subsession))
                contents[row.id] = row
            }
        }
        return contents
    }

    /// Whether `ws` has a nested row to list.
    static func nests(_ ws: SidebarWorkspace) -> Bool {
        ws.tabs.contains { !$0.subsessions.isEmpty }
    }

    /// What decides which nested rows `ws` lists (each parent tab, its sub-sessions, and whether
    /// one is active): a row patch that changes it lays the list out again.
    static func shape(_ ws: SidebarWorkspace) -> [String] {
        ws.tabs.filter { !$0.subsessions.isEmpty }.map { tab in
            ([tab.id.rawValue, tab.subsessions.contains { $0.state.isActive } ? "1" : "0"] + tab.subsessions.map(\.id))
                .joined(separator: "\u{1F}")
        }
    }
}
