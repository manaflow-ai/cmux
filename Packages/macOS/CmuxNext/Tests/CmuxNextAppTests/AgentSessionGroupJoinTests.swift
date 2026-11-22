@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-22: "you also just kept adding them to same-named groups...? this doenst seem rightr".
/// Re-homing the GUI push lanes put each new lane's workspace (`acpmux new --group`, `cmux agent open
/// --group`) in a NEW "GUI push · lanes" group, nine of them, instead of the one the sidebar had, and
/// each re-homed lane got a second row next to its predecessor's. A named group is joined when any group
/// of that name can hold the workspace, wherever it is listed; one is made only when none can. A lane
/// whose name already has a row in that group reuses that row.
@Suite struct AgentSessionGroupJoinTests {
    static let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let other = SidebarMachine(id: MachineID("big-red"), name: "big-red", kind: .ssh)
    static let lanes = "GUI push · lanes"

    static func row(_ id: String, title: String? = nil, on machine: MachineID = .local) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), machineID: machine, title: title ?? id)
    }

    @Test func theGroupOfThatNameTakesTheWorkspace() {
        let sections = [SidebarSection(kind: .machine(Self.local), nodes: [
            .group(SidebarGroup(id: GroupID("g1"), name: Self.lanes, workspaces: [Self.row("a")])),
            .workspace(Self.row("n")),
        ])]
        #expect(SidebarEdits.group(named: Self.lanes, accepting: WorkspaceID("n"), in: sections) == GroupID("g1"))
    }

    @Test func aSameNamedGroupThatCannotHoldItIsSkippedNotDuplicated() {
        // The first "GUI push · lanes" holds another machine's rows only; the second can take `n`.
        let sections = [
            SidebarSection(kind: .machine(Self.other), nodes: [
                .group(SidebarGroup(id: GroupID("remote"), name: Self.lanes,
                                    workspaces: [Self.row("r", on: MachineID("big-red"))])),
            ]),
            SidebarSection(kind: .machine(Self.local), nodes: [
                .group(SidebarGroup(id: GroupID("g2"), name: Self.lanes, workspaces: [Self.row("a")])),
                .workspace(Self.row("n")),
            ]),
        ]
        #expect(SidebarEdits.group(named: Self.lanes, accepting: WorkspaceID("n"), in: sections) == GroupID("g2"))
    }

    @Test func noGroupThatCanHoldItMeansANewOne() {
        let sections = [
            SidebarSection(kind: .machine(Self.other), nodes: [
                .group(SidebarGroup(id: GroupID("remote"), name: Self.lanes,
                                    workspaces: [Self.row("r", on: MachineID("big-red"))])),
            ]),
            SidebarSection(kind: .machine(Self.local), nodes: [
                .group(SidebarGroup(id: GroupID("g3"), name: "other", workspaces: [Self.row("a")])),
                .workspace(Self.row("n")),
            ]),
        ]
        #expect(SidebarEdits.group(named: Self.lanes, accepting: WorkspaceID("n"), in: sections) == nil)
    }

    @Test func aReHomedLaneFindsItsPredecessorsRowInTheGroup() {
        let sections = [SidebarSection(kind: .machine(Self.local), nodes: [
            .group(SidebarGroup(id: GroupID("g1"), name: Self.lanes,
                                workspaces: [Self.row("p", title: "pane-motion"), Self.row("q", title: "pr-cards")])),
            .group(SidebarGroup(id: GroupID("g2"), name: "elsewhere", workspaces: [Self.row("x", title: "deeplink-message")])),
            .workspace(Self.row("y", title: "pane-motion")),
        ])]
        #expect(SidebarEdits.predecessor(named: "pane-motion", inGroup: Self.lanes, in: sections) == WorkspaceID("p"))
        // Only a row in that group: a loose row or another group's row of that name is someone else's.
        #expect(SidebarEdits.predecessor(named: "deeplink-message", inGroup: Self.lanes, in: sections) == nil)
        #expect(SidebarEdits.predecessor(named: "prompt-queue-edit", inGroup: Self.lanes, in: sections) == nil)
    }

    @Test func anotherMachinesRowIsNeverAPredecessor() {
        // A custom section's group may hold any machine's rows; the chat opens on this Mac's daemon.
        let custom = SidebarCustomSection(id: "c", title: "Custom")
        let sections = [SidebarSection(kind: .custom(custom), nodes: [
            .group(SidebarGroup(id: GroupID("g1"), name: Self.lanes,
                                workspaces: [Self.row("r", title: "pane-motion", on: MachineID("big-red"))])),
        ])]
        #expect(SidebarEdits.predecessor(named: "pane-motion", inGroup: Self.lanes, in: sections) == nil)
    }

    @Test func groupNamesRejectObjectIdsAndBlankLabels() {
        for name in ["", "  ", "grp_012345", "ws_012345", "550e8400-e29b-41d4-a716-446655440000"] {
            #expect(!SidebarEdits.validGroupName(name), "\(name)")
        }
        #expect(SidebarEdits.validGroupName("GUI push"))
    }

    /// cmuxterm-hq#4976: `--group "gui push"` or `"GUI push "` made a second "GUI push" group, since names
    /// matched only exactly. The same label typed another way joins the group; an exact name still wins.
    @Test func theSameLabelTypedAnotherWayJoinsTheGroup() {
        let sections = [SidebarSection(kind: .machine(Self.local), nodes: [
            .group(SidebarGroup(id: GroupID("g1"), name: "GUI push", workspaces: [Self.row("p", title: "pane-motion")])),
            .workspace(Self.row("n")),
        ])]
        for asked in ["gui push", "GUI push ", "  Gui Push\n"] {
            #expect(SidebarEdits.group(named: asked, accepting: WorkspaceID("n"), in: sections) == GroupID("g1"), "\(asked)")
            #expect(SidebarEdits.predecessor(named: "pane-motion", inGroup: asked, in: sections) == WorkspaceID("p"), "\(asked)")
        }
        #expect(SidebarEdits.group(named: "GUI pushes", accepting: WorkspaceID("n"), in: sections) == nil)

        let both = [SidebarSection(kind: .machine(Self.local), nodes: [
            .group(SidebarGroup(id: GroupID("upper"), name: "GUI push", workspaces: [Self.row("a")])),
            .group(SidebarGroup(id: GroupID("lower"), name: "gui push", workspaces: [Self.row("b")])),
            .workspace(Self.row("n")),
        ])]
        #expect(SidebarEdits.group(named: "gui push", accepting: WorkspaceID("n"), in: both) == GroupID("lower"))

        // The same for a re-homed lane's row: the exactly named group's row wins over a case variant's.
        let rows = [SidebarSection(kind: .machine(Self.local), nodes: [
            .group(SidebarGroup(id: GroupID("upper"), name: "GUI push", workspaces: [Self.row("u", title: "pane-motion")])),
            .group(SidebarGroup(id: GroupID("lower"), name: "gui push", workspaces: [Self.row("l", title: "pane-motion")])),
        ])]
        #expect(SidebarEdits.predecessor(named: "pane-motion", inGroup: "gui push", in: rows) == WorkspaceID("l"))
        #expect(SidebarEdits.predecessor(named: "pane-motion", inGroup: "GUI push", in: rows) == WorkspaceID("u"))

        // Across windows (each sidebar lists only its own rows): a later window's exact group beats an earlier
        // window's case variant, as exact matching alone found it before.
        let first = [SidebarSection(kind: .machine(Self.local), nodes: [
            .group(SidebarGroup(id: GroupID("upper"), name: "GUI push", workspaces: [Self.row("u", title: "pane-motion")])),
        ])]
        let second = [SidebarSection(kind: .machine(Self.local), nodes: [
            .group(SidebarGroup(id: GroupID("lower"), name: "gui push", workspaces: [Self.row("l", title: "pane-motion")])),
        ])]
        #expect(SidebarEdits.predecessor(named: "pane-motion", inGroup: "gui push", inEach: [first, second]) == WorkspaceID("l"))
        #expect(SidebarEdits.predecessor(named: "pane-motion", inGroup: "Gui Push", inEach: [first, second]) == WorkspaceID("u"))

        // An exactly named group without the row gets a new row in it (nil here), not a case variant's row.
        let noRow = [SidebarSection(kind: .machine(Self.local), nodes: [
            .group(SidebarGroup(id: GroupID("upper"), name: "GUI push", workspaces: [Self.row("u", title: "pane-motion")])),
            .group(SidebarGroup(id: GroupID("lower"), name: "gui push", workspaces: [Self.row("o", title: "other")])),
            .workspace(Self.row("n")),
        ])]
        #expect(SidebarEdits.predecessor(named: "pane-motion", inGroup: "gui push", in: noRow) == nil)
        #expect(SidebarEdits.predecessor(named: "pane-motion", inGroup: "gui push", inEach: [noRow, first]) == nil)

        // A name with outer spaces that a group has exactly is found exactly, not trimmed onto another group.
        let padded = [SidebarSection(kind: .machine(Self.local), nodes: [
            .group(SidebarGroup(id: GroupID("plain"), name: "GUI push", workspaces: [Self.row("a", title: "pane-motion")])),
            .group(SidebarGroup(id: GroupID("padded"), name: "GUI push ", workspaces: [Self.row("b", title: "pane-motion")])),
            .workspace(Self.row("n")),
        ])]
        #expect(SidebarEdits.group(named: "GUI push ", accepting: WorkspaceID("n"), in: padded) == GroupID("padded"))
        #expect(SidebarEdits.predecessor(named: "pane-motion", inGroup: "GUI push ", in: padded) == WorkspaceID("b"))
    }
}
