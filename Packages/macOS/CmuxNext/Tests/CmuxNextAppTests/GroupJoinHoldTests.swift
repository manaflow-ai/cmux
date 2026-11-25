@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-03: "i hate it when you guys make new worksapces or whatever and they appear for a split second and
/// it's just bloop and then it goes into presumably whichever group... it's just weird how it flickers into some top
/// level group or whatever then goes away". A workspace `acpmux new --group` opens lists loose in the daemon's
/// create, then joins its group a hop later. Every pass the sidebar draws shows it in its group or not at all.
@Suite struct GroupJoinHoldTests {
    static let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let other = SidebarMachine(id: MachineID("big-red"), name: "big-red", kind: .ssh)

    static func row(_ id: String, on machine: MachineID = .local) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), machineID: machine, title: id)
    }

    /// The daemon's create: `n` lists loose above the group.
    static let created = [SidebarSection(kind: .machine(local), nodes: [
        .workspace(row("n")),
        .group(SidebarGroup(id: GroupID("g"), name: "lanes", workspaces: [row("a")])),
        .workspace(row("b")),
    ])]
    /// The join landed: `n` lists in `g`.
    static let joined = [SidebarSection(kind: .machine(local), nodes: [
        .group(SidebarGroup(id: GroupID("g"), name: "lanes", workspaces: [row("a"), row("n")])),
        .workspace(row("b")),
    ])]

    /// The ids a pass draws outside any group.
    static func loose(_ sections: [SidebarSection]) -> [String] {
        sections.flatMap(\.nodes).compactMap { node in
            if case let .workspace(workspace) = node { return workspace.id.rawValue }
            return nil
        }
    }

    /// One pass as the sidebar runs it: what it draws, and the joins it sends after drawing (claimed, as `takeDue`).
    static func pass(_ hold: inout GroupJoinHold, _ sections: [SidebarSection], catchingUp: Bool = false) -> (drawn: [SidebarSection], sent: [String]) {
        let (hidden, due) = hold.pass(over: sections, catchingUp: catchingUp)
        return (SidebarEdits.removing(hidden, from: sections), due.filter { hold.claim($0.id) }.map(\.id))
    }

    /// The pass that first lists the create leaves it out and sends its join; the document's move (its optimistic look)
    /// lists it in its group on the next pass. No pass draws it loose, and nothing waits on a clock.
    @Test func aGroupedCreateJoinsInItsFirstPassAndNeverDrawsLoose() {
        var hold = GroupJoinHold()
        hold.hold("n", group: "lanes")
        let first = Self.pass(&hold, Self.created)
        #expect(first.sent == ["n"], "the first pass that lists it sends its join")
        #expect(!Self.loose(first.drawn).contains("n"), "n drew loose before its group")
        #expect(Self.loose(first.drawn) == ["b"], "no other row is left out")
        // The document applied the move and shows it a hop later: still out, no second join.
        let lagging = Self.pass(&hold, Self.created, catchingUp: true)
        #expect(lagging.sent.isEmpty && !Self.loose(lagging.drawn).contains("n"))
        let joined = Self.pass(&hold, Self.joined)
        #expect(SidebarEdits.workspace(WorkspaceID("n"), in: joined.drawn) != nil, "n draws in its group")
        #expect(hold.isEmpty, "listing in its group releases it")
    }

    /// A join the document did not take (refused): once the document shows its own state, the row shows where it lists.
    @Test func aRefusedJoinShowsTheRowWithNoTimer() {
        var hold = GroupJoinHold()
        hold.hold("n", group: "lanes")
        #expect(Self.pass(&hold, Self.created).sent == ["n"])
        let after = Self.pass(&hold, Self.created, catchingUp: false)
        #expect(Self.loose(after.drawn).contains("n"), "a refused join hid the row")
        #expect(after.sent.isEmpty, "a refused join is not sent again")
        #expect(hold.isEmpty)
    }

    /// The create's placement may send the join before any pass lists the row: the pass sends none again.
    @Test func aJoinIsSentOnce() {
        var hold = GroupJoinHold()
        hold.hold("n", group: "lanes")
        let placed = hold.claim("n")
        #expect(placed, "the placement sends it")
        let first = Self.pass(&hold, Self.created, catchingUp: true)
        #expect(first.sent.isEmpty && !Self.loose(first.drawn).contains("n"))
        let again = hold.claim("n")
        #expect(!again)
        var empty = GroupJoinHold()
        let loose = empty.claim("x")
        #expect(loose, "a workspace not held joins as before")
    }

    @Test func aSlowCreateIsHeldUntilItLists() {
        var hold = GroupJoinHold()
        hold.hold("n", group: "lanes")
        let unlisted = Self.joined.map { var s = $0; s.nodes.removeFirst(); return s }
        #expect(Self.pass(&hold, unlisted).sent.isEmpty, "not listed yet: nothing to join")
        #expect(hold.holds("n"))
        #expect(Self.pass(&hold, Self.created).sent == ["n"])
    }

    @Test func aReleasedCreateIsNotHeld() {
        var hold = GroupJoinHold()
        hold.hold("n", group: "lanes")
        hold.release("n")
        let pass = Self.pass(&hold, Self.created)
        #expect(pass.sent.isEmpty && Self.loose(pass.drawn).contains("n"))
    }

    /// A held grouped create draws no stand-in row: a stand-in has no group slot and would draw loose for a frame.
    @MainActor @Test func aHeldGroupedCreateDrawsNoStandIn() {
        let rows = PendingWorkspaceRows.shared
        rows.add(creating: "held-n", window: "w-hold", machine: .local, name: "n", opensPage: true, slot: nil, byDefault: nil, unpinned: true)
        defer { rows.remove("held-n"); rows.groupJoins.release("held-n") }
        #expect(rows.rows(in: "w-hold").map(\.id) == ["held-n"])
        rows.groupJoins.hold("held-n", group: "lanes")
        #expect(rows.rows(in: "w-hold").isEmpty, "a held grouped create drew its stand-in")
        rows.groupJoins.release("held-n")
        #expect(rows.rows(in: "w-hold").map(\.id) == ["held-n"])
    }

    /// The join reads the window's rows, which leave the held row out: the named group takes it by its machine.
    @Test func theNamedGroupTakesAHeldRowByItsMachine() {
        let sections = [
            SidebarSection(kind: .machine(Self.other), nodes: [
                .group(SidebarGroup(id: GroupID("remote"), name: "lanes", workspaces: [Self.row("r", on: MachineID("big-red"))])),
            ]),
            SidebarSection(kind: .machine(Self.local), nodes: [
                .group(SidebarGroup(id: GroupID("g"), name: "lanes", workspaces: [Self.row("a")])),
            ]),
        ]
        #expect(SidebarEdits.group(named: "lanes", accepting: WorkspaceID("n"), in: sections) == nil, "unlisted, no machine: none")
        #expect(SidebarEdits.group(named: "lanes", accepting: WorkspaceID("n"), in: sections, machine: .local) == GroupID("g"))
        #expect(SidebarEdits.group(named: "lanes", accepting: WorkspaceID("n"), in: sections, machine: MachineID("big-red")) == GroupID("remote"))
    }
}
