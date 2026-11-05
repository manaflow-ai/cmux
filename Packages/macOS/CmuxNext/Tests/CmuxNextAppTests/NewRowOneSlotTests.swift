import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextSettings
@testable import CmuxNextSidebar
import Testing

/// A new workspace's row draws once, at the slot it keeps: the pending row, the not-yet-placed row and the
/// daemon's place agree, so the row never moves after it appears (the sidebar animated a second move: "it over
/// animates more than necessary"). Pure: slots and the placement ledger, no app.
@MainActor @Suite struct NewRowOneSlotTests {
    private static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    private static let section = SectionID.machine(machine.id)
    private static func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// `bottom` with a group at the end of the section: last in the section, below the group, where the daemon
    /// appends it and the document lists it before it places it. The slot after the last loose row drew the
    /// pending row above the group, then the row moved below it.
    @Test func bottomListsBelowATrailingGroup() throws {
        let group = SidebarGroup(id: GroupID("g-tail"), name: "Tail", color: .green, workspaces: ["c", "d"].map(Self.ws))
        let sections = [SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(Self.ws("a")), .workspace(Self.ws("b")), .group(group)])]
        let position = try #require(WorkspaceSlot.bottom(anchor: nil).position(moving: ["new"], section: Self.section, in: sections))
        #expect(position == DropPosition(section: Self.section, index: 3), "bottom resolved to \(position)")
    }

    /// While the window's rows catch up, a current row not listed yet holds every placement's default slot, not only
    /// `beforeCurrent` / `afterCurrent`: `top` and `bottom` resolve inside the current workspace's group too, and a
    /// slot read without it drew the row at the section's top or end, then moved it into the group.
    @Test(arguments: [NewWorkspacePlacement.top, .bottom, .beforeCurrent, .afterCurrent])
    func everyPlacementWaitsForTheCurrentRowWhileCatchingUp(placement: NewWorkspacePlacement) {
        let sections = [SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(Self.ws("a"))])]
        let rule = NewWorkspaceDefaultSlot(placement: placement, current: "grouped", currentMachine: Self.machine.id.rawValue)
        #expect(rule.awaitsCurrentAnchor(section: Self.section, in: sections, catchingUp: true))
        #expect(!rule.awaitsCurrentAnchor(section: Self.section, in: sections, catchingUp: false))
    }

    /// An anchor lasts until its workspace's document item exists, never by count: with more than 16 creates in
    /// flight, a create not sent yet (no workspace, not `placedByDaemon`) lost its anchor, and its row listed at the
    /// end for a hop, then moved beside its neighbour.
    @Test func anAnchorOutlivesManyCreatesInFlight() {
        let ledger = WorkspacePlacementLedger()
        for index in 0..<20 { ledger.anchors["k\(index)"] = .after("old") }
        let anchor = ledger.unplacedAnchor(for: "k0", hasDocumentItem: { _ in false }, workspaceExists: { _ in false })
        #expect(anchor == .after("old"))
        #expect(ledger.anchors.count == 20)
    }

    /// The anchor ends when the document places its workspace, or when its workspace, once listed, is gone.
    @Test func anAnchorEndsWhenPlacedOrClosed() {
        let ledger = WorkspacePlacementLedger()
        ledger.anchors["placed"] = .after("old")
        ledger.anchors["closed"] = .after("old")
        var listed: Set<String> = ["closed"]
        _ = ledger.unplacedAnchor(for: "closed", hasDocumentItem: { $0 == "placed" }, workspaceExists: { listed.contains($0) })
        #expect(ledger.anchors["placed"] == nil)
        #expect(ledger.anchors["closed"] == .after("old"))
        listed = []
        #expect(ledger.unplacedAnchor(for: "closed", hasDocumentItem: { _ in false }, workspaceExists: { listed.contains($0) }) == nil)
        #expect(ledger.anchors.isEmpty)
    }
}
