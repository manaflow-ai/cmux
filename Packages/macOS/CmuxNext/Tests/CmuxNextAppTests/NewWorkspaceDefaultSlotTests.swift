import CmuxNextBridge
import CmuxNextSettings
@testable import CmuxNextSidebar
import Testing

/// `NewWorkspaceDefaultSlot` lives in CmuxNextBridge (moved out of CmuxNextApp with no behavior change). These pin
/// each of its decisions as they were in the app, through the package alone (no `CmuxNextApp` import): the slot for a
/// new workspace under each `workspaces.newPlacement`, the move the app sends for it, the cold-layout anchor wait,
/// the catching-up read and the in-group slot.
@Suite struct NewWorkspaceDefaultSlotTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let section = SectionID.machine(.local)
    static let g1 = GroupID("g1")

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// Optional Home; loose `a`; group `g1` (`c`, `d`, `e`); loose `f`; the new workspace `n` last, where the daemon lists it.
    static func sections(home: Bool = false) -> [SidebarSection] {
        [SidebarSection(kind: .machine(machine), nodes: (home ? [.workspace(row("home"))] : []) + [
            .workspace(row("a")),
            .group(SidebarGroup(id: g1, name: "one", workspaces: [row("c"), row("d"), row("e")])),
            .workspace(row("f")),
            .workspace(row("n")),
        ])]
    }

    static func slot(_ rule: NewWorkspaceDefaultSlot, home: Bool = false, catchingUp: Bool = false) -> WorkspaceSlot? {
        rule.slot(for: "n", section: section, in: sections(home: home), home: home ? "home" : nil, catchingUp: catchingUp)
    }

    static func move(_ rule: NewWorkspaceDefaultSlot, home: Bool = false) -> WorkspaceSlot? {
        rule.move(for: "n", section: section, in: sections(home: home), home: home ? "home" : nil)
    }

    @Test func topIsTheSectionsFirstSlotAndSendsNoMove() {
        let rule = NewWorkspaceDefaultSlot(placement: .top, current: nil)
        #expect(Self.slot(rule) == .top(anchor: nil))
        #expect(Self.move(rule) == nil)
        // A loose current workspace changes nothing: still the section's top.
        #expect(Self.slot(NewWorkspaceDefaultSlot(placement: .top, current: "a")) == .top(anchor: nil))
    }

    @Test func topStaysBelowHome() {
        let rule = NewWorkspaceDefaultSlot(placement: .top, current: nil)
        #expect(Self.slot(rule, home: true) == .below("home"))
        #expect(Self.move(rule, home: true) == nil)
    }

    @Test func topInAGroupIsTheGroupsTopAndIsMoved() {
        let rule = NewWorkspaceDefaultSlot(placement: .top, current: "d")
        #expect(Self.slot(rule) == .top(anchor: "d"))
        #expect(Self.move(rule) == .top(anchor: "d"))
    }

    @Test func aNamedTopIsMovedEvenAtTheSectionsTop() {
        let rule = NewWorkspaceDefaultSlot(placement: .top, current: nil, named: true)
        #expect(Self.move(rule) == .top(anchor: nil))
    }

    @Test func afterCurrentIsBelowTheCurrentAndAlwaysMoved() {
        let rule = NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "a")
        #expect(Self.slot(rule) == .below("a"))
        #expect(Self.move(rule) == .below("a"))
        // An unlisted current (pinned, another machine) falls back to the top, still sent as a move.
        let unlisted = NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "elsewhere")
        #expect(Self.slot(unlisted) == .top(anchor: nil))
        #expect(Self.move(unlisted) == .top(anchor: nil))
        // The new workspace itself as the current one: the top.
        #expect(Self.slot(NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "n")) == .top(anchor: nil))
    }

    @Test func bottomMovesOnlyInsideAGroup() {
        #expect(Self.slot(NewWorkspaceDefaultSlot(placement: .bottom, current: "d")) == .bottom(anchor: "d"))
        #expect(Self.slot(NewWorkspaceDefaultSlot(placement: .bottom, current: "a")) == nil)
        #expect(Self.slot(NewWorkspaceDefaultSlot(placement: .bottom, current: nil)) == nil)
        #expect(Self.move(NewWorkspaceDefaultSlot(placement: .bottom, current: nil)) == nil)
    }

    @Test func aColdLayoutWaitsOnlyForAMissingCurrentOnItsOwnMachine() {
        let rule = NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "late", currentMachine: MachineID.local.rawValue)
        let sections = Self.sections()
        #expect(rule.awaitsCurrentAnchor(section: Self.section, in: sections, catchingUp: true))
        #expect(Self.slot(rule, catchingUp: true) == nil)
        // Caught up: the row was left out on purpose; the fallback applies.
        #expect(!rule.awaitsCurrentAnchor(section: Self.section, in: sections, catchingUp: false))
        #expect(Self.slot(rule) == .top(anchor: nil))
        // Listed, Home, another machine or no machine (a band row): no wait.
        let listed = NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "a", currentMachine: MachineID.local.rawValue)
        #expect(!listed.awaitsCurrentAnchor(section: Self.section, in: sections, catchingUp: true))
        let home = NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "home", currentMachine: MachineID.local.rawValue)
        #expect(!home.awaitsCurrentAnchor(section: Self.section, in: sections, home: "home", catchingUp: true))
        let other = NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "late", currentMachine: "cloud-1")
        #expect(!other.awaitsCurrentAnchor(section: Self.section, in: sections, catchingUp: true))
        let band = NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "late", currentMachine: nil)
        #expect(!band.awaitsCurrentAnchor(section: Self.section, in: sections, catchingUp: true))
        // Every placement waits: `top` and `bottom` resolve inside the current workspace's group too (NewRowOneSlotTests).
        let top = NewWorkspaceDefaultSlot(placement: .top, current: "late", currentMachine: MachineID.local.rawValue)
        #expect(top.awaitsCurrentAnchor(section: Self.section, in: sections, catchingUp: true))
    }

    @Test func noSidebarDocumentIsNeverCatchingUp() {
        #expect(!NewWorkspaceDefaultSlot.layoutCatchingUp(nil))
        #expect(!NewWorkspaceDefaultSlot.layoutCatchingUp(nil, rowsAt: 3))
    }

    @Test func theInGroupSlotFollowsThePlacement() {
        let members = ["c", "d", "e"]
        #expect(NewWorkspaceDefaultSlot(placement: .top, current: "d").slot(inGroup: Self.g1, members: members) == .top(anchor: "c"))
        #expect(NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "d").slot(inGroup: Self.g1, members: members)
            == .first([.below("d"), .endOfGroup(Self.g1)]))
        #expect(NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "a").slot(inGroup: Self.g1, members: members) == .endOfGroup(Self.g1))
        #expect(NewWorkspaceDefaultSlot(placement: .bottom, current: "d").slot(inGroup: Self.g1, members: members) == .endOfGroup(Self.g1))
        #expect(NewWorkspaceDefaultSlot(placement: .top, current: nil).slot(inGroup: Self.g1, members: []) == .endOfGroup(Self.g1))
    }
}
