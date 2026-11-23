import CmuxNextDesign
import CoreGraphics

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): the mock sidebar each playground column draws, one row
/// per ``SidebarStatesPlaygroundState``: Home and a pinned workspace in the top bands, then This Mac's rows and groups
/// (the archived row under the open Archive section), then one row on an SSH machine. ``ref(for:)`` says which real
/// row view draws each state.
struct SidebarStatesPlaygroundFixture {
    /// Where a state's row view lives: a list row, or an item of a band block (Home, a pin).
    enum Ref: Hashable {
        case list(SidebarRowKey)
        case band(block: String, item: LayoutItemID)
    }

    static let home = LayoutItemID("sp_home"), pin = LayoutItemID("sp_pin")
    static let pinnedWorkspace = WorkspaceID("sp-pinned")
    static let idle = WorkspaceID("sp-idle"), busy = WorkspaceID("sp-busy"), unread = WorkspaceID("sp-unread")
    static let needsYou = WorkspaceID("sp-needs-you"), error = WorkspaceID("sp-error"), needsInput = WorkspaceID("sp-needs-input")
    static let usageWarning = WorkspaceID("sp-usage-warning"), selected = WorkspaceID("sp-selected")
    static let hovered = WorkspaceID("sp-hovered"), renaming = WorkspaceID("sp-renaming"), archived = WorkspaceID("sp-archived")
    static let remote = WorkspaceID("sp-remote"), member = WorkspaceID("sp-member"), accent = WorkspaceID("sp-accent")
    static let faviconMono = WorkspaceID("sp-favicon-mono"), faviconColorful = WorkspaceID("sp-favicon-colorful")
    static let faviconMissing = WorkspaceID("sp-favicon-missing")
    static let open = GroupID("sp-open"), collapsed = GroupID("sp-collapsed"), empty = GroupID("sp-empty")
    static let remoteMachine = MachineID("sp-ssh")

    /// The pinned workspace the pin opens, with the tabs its hover card lists.
    static var pinnedRow: SidebarWorkspace {
        var row = SidebarWorkspace(id: pinnedWorkspace, machineID: .local, title: "Pinned workspace", directory: "~/fun/cmux",
                                   branch: "feat-cmux-next", kind: .terminal)
        row.lastMessage = "Pushed the fix and the gallery"
        row.tabs = [
            SidebarTab(id: TabID("sp-pin-chat"), title: "Claude Code", kind: .agentChat, folder: "~/fun/cmux", state: .success),
            SidebarTab(id: TabID("sp-pin-terminal"), title: "Terminal", kind: .terminal, folder: "~/fun/cmux"),
            SidebarTab(id: TabID("sp-pin-docs"), title: "Documentation", kind: .browser),
        ]
        return row
    }

    /// The row that draws `state`.
    func ref(for state: SidebarStatesPlaygroundState) -> Ref {
        switch state {
        case .idle: .list(.workspace(Self.idle))
        case .busy: .list(.workspace(Self.busy))
        case .unread: .list(.workspace(Self.unread))
        case .needsYou: .list(.workspace(Self.needsYou))
        case .error: .list(.workspace(Self.error))
        case .needsInput: .list(.workspace(Self.needsInput))
        case .usageWarning: .list(.workspace(Self.usageWarning))
        case .pinned, .pinnedHoverCard: .band(block: SidebarLayoutDocument.pinnedSectionID.rawValue, item: Self.pin)
        case .selected: .list(.workspace(Self.selected))
        case .hovered: .list(.workspace(Self.hovered))
        case .renaming: .list(.workspace(Self.renaming))
        case .archived: .list(.workspace(Self.archived))
        case .remote: .list(.workspace(Self.remote))
        case .groupExpanded: .list(.group(Self.open))
        case .groupCollapsed: .list(.group(Self.collapsed))
        case .home: .band(block: SidebarLayoutDocument.topSectionID.rawValue, item: Self.home)
        case .emptyGroup: .list(.group(Self.empty))
        case .accentBar: .list(.workspace(Self.accent))
        case .groupRail: .list(.workspace(Self.member))
        case .faviconMono: .list(.workspace(Self.faviconMono))
        case .faviconColorful: .list(.workspace(Self.faviconColorful))
        case .faviconMissing: .list(.workspace(Self.faviconMissing))
        }
    }

    /// The mock sidebar, its rows two lines tall when `expanded` (the Expanded density).
    @MainActor func model(expanded: Bool) -> SidebarModel {
        func row(_ id: WorkspaceID, _ title: String, machine: MachineID = .local, unread: UnreadState = .none,
                 activity: StatusIndicatorState = .idle, color: GroupColor? = nil) -> SidebarWorkspace {
            // A working or waiting mark draws only while an agent works in the row (WORKING-AND-LOADING-INDICATORS).
            var row = SidebarWorkspace(id: id, machineID: machine, title: title, directory: "~/fun/cmux", branch: "feat-cmux-next",
                                       agentWorking: activity != .idle, color: color, kind: .terminal, unread: unread,
                                       activity: activity)
            row.lastMessage = "Pushed the fix and the gallery"
            return row
        }
        var needsInput = row(Self.needsInput, "Program asks a question", activity: .waiting(kind: .question))
        needsInput.activityFromProgram = true // an OSC 7501 report opts its row in to the detailed marks
        var usage = row(Self.usageWarning, "Runaway agent chat")
        usage.usageWarnings = ["No autocompact cap"]
        let favicons = SidebarStatesPlaygroundFavicons()
        func browser(_ id: WorkspaceID, _ title: String, _ image: CGImage?) -> SidebarWorkspace {
            var row = row(id, title)
            row.kind = .browser
            // A site with no favicon draws the placeholder globe, as `SidebarMapping.row` maps it.
            row.icon = image.map { .favicon(SidebarFavicon($0)) } ?? .pagePlaceholder
            return row
        }
        var archived = row(Self.archived, "Archived workspace")
        archived.isArchived = true
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list,
                                items: [LayoutItem(id: Self.home, ref: SidebarLayoutDocument.homeRef)])
        let pinned = SidebarLayoutDocument.pinnedSection(items: [LayoutItem(id: Self.pin, ref: .workspace(Self.pinnedWorkspace.rawValue))])
        let local = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            // Colored, so the selected and hovered rows show the leading accent bar in those states (Lawrence msg 19775).
            .workspace(row(Self.selected, "Selected workspace", color: .purple)),
            .workspace(row(Self.idle, "Idle workspace")),
            .workspace(row(Self.busy, "Agent working", activity: .working)),
            .workspace(row(Self.unread, "Unread reply", unread: .dot)),
            .workspace(row(Self.needsYou, "Agent needs you", activity: .waiting)),
            .workspace(row(Self.error, "Build failed", activity: .error)),
            .workspace(needsInput),
            .workspace(usage),
            .workspace(row(Self.hovered, "Hovered workspace", color: .purple)),
            .workspace(row(Self.accent, "Colored workspace", color: .purple)),
            .workspace(row(Self.renaming, "Renaming workspace")),
            .workspace(browser(Self.faviconMono, "github.com", favicons.mono)),
            .workspace(browser(Self.faviconColorful, "google.com", favicons.colorful)),
            .workspace(browser(Self.faviconMissing, "example.com", nil)),
            .group(SidebarGroup(id: Self.open, name: "Open group", color: .blue, workspaces: [row(Self.member, "Group member")])),
            .group(SidebarGroup(id: Self.collapsed, name: "Collapsed group", color: .purple, isCollapsed: true, workspaces: [
                row(WorkspaceID("sp-rollup-working"), "Rolled-up working", activity: .working),
                row(WorkspaceID("sp-rollup-waiting"), "Rolled-up needs you", activity: .waiting),
                row(WorkspaceID("sp-rollup-unread"), "Rolled-up unread", unread: .dot),
            ])),
            .group(SidebarGroup(id: Self.empty, name: "Empty group", color: .green, workspaces: [])),
            .workspace(archived),
        ])
        let remote = SidebarSection(kind: .machine(SidebarMachine(id: Self.remoteMachine, name: "build-box", kind: .ssh)),
                                    nodes: [.workspace(row(Self.remote, "Remote workspace", machine: Self.remoteMachine))])
        let model = SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
            local, remote,
        ], activeWorkspaceID: Self.selected)
        model.layout = SidebarLayoutDocument(sections: [top, pinned])
        var home = SidebarItemInfo.fallback(for: top.items[0])
        home.unreadDot = true
        var pin = SidebarItemInfo(title: "Pinned workspace", symbol: "textformat")
        pin.textOnly = true
        pin.workspace = Self.pinnedWorkspace
        pin.workspaceRow = Self.pinnedRow
        model.itemInfo = [Self.home: home, Self.pin: pin]
        model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
        model.expanded = expanded
        model.colorIndicator = .leftRail // a colored row's color is its leading bar
        return model
    }
}
