/// Debug Settings `sidebar.rowTitlePreview` (`SidebarTunables.rowTitlePreview`): a section of
/// sample workspaces with several tabs, so each `sidebar.rowTitle` mode can be seen without real
/// sessions (the `sidebar-row-title` tour cycles them). The words are fixture data, like a mock's.
/// The rows are placeholders: nothing selects, opens or closes them.
extension SidebarSection {
    static let rowTitlePreviewMachine = MachineID("row-title-preview")

    /// The Debug Settings preview sections that are on: `sidebar.rowBadgePreview`, `sidebar.rowTitlePreview`.
    public static func debugPreviews() -> [SidebarSection] {
        (SidebarTunables.rowBadgePreview.value ? rowBadgePreview() : []) + (SidebarTunables.rowTitlePreview.value ? rowTitlePreview() : [])
    }

    /// The preview rows' section: a chat with a terminal and a page beside it, a workspace that is
    /// one chat, terminals only, a one-chat workspace named after its chat (cmux#25416), and a
    /// page in front of a chat.
    public static func rowTitlePreview() -> [SidebarSection] {
        let machine = rowTitlePreviewMachine
        typealias Tab = (title: String, kind: SidebarTabKind)
        let rows: [(name: String, tabs: [Tab], focused: Int, kind: SidebarWorkspaceKind)] = [
            ("Sidebar breadcrumb", [("Draft the breadcrumb row", .agentChat), ("zsh", .terminal), ("Pull request #25416", .browser)], 0, .harness),
            ("Release notes", [("Write the October release notes", .agentChat)], 0, .harness),
            ("api", [("zsh", .terminal), ("npm run dev", .terminal), ("tail -f server.log", .terminal)], 1, .terminal),
            ("Fix login redirect", [("Fix login redirect", .agentChat)], 0, .harness),
            ("Docs site", [("Rewrite the install page", .agentChat), ("Getting started · cmux docs", .browser)], 1, .browser),
        ]
        let nodes = rows.enumerated().map { index, sample in
            let tabs = sample.tabs.enumerated().map { tab, entry in
                SidebarTab(id: TabID("row-title-preview-\(index)-\(tab)"), title: entry.title, kind: entry.kind)
            }
            var row = SidebarWorkspace(
                id: WorkspaceID("row-title-preview-\(index)"), machineID: machine, title: sample.name, kind: sample.kind,
                tabs: tabs, rowState: .placeholder, isClosable: false)
            row.focusedTab = tabs[sample.focused].id
            return SidebarNode.workspace(row)
        }
        return [SidebarSection(kind: .machine(SidebarMachine(id: machine, name: "Row name preview", kind: .server)), nodes: nodes)]
    }
}
