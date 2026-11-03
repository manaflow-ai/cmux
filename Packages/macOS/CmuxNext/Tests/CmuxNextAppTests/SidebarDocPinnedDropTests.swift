@testable import CmuxNextSidebar
import Testing

/// A workspace dragged from the list between two pinned workspaces became a
/// pin by the drop. Pinned takes a drop only of items already in it, so no
/// gap opens there; Pin is the way in (https://github.com/manaflow-ai/cmux/issues/22259).
@Suite struct SidebarDocPinnedDropTests {
    static let pinned = SidebarDocStore.pinnedSection
    static let machine = "sec_m_s-local"

    static func records() -> SidebarDocRecords {
        let workspace = { (id: String, section: String) in
            SidebarDocItem(id: id, section: section, body: .workspace(SidebarDocWorkspaceRef(sessionID: "s-local", workspaceID: id)))
        }
        return SidebarDocRecords(items: [
            "itm_p1": workspace("itm_p1", pinned),
            "itm_p2": workspace("itm_p2", pinned),
            "itm_loose": workspace("itm_loose", machine),
            "itm_other": workspace("itm_other", machine),
        ])
    }

    /// Every row and section accepting a drop beside it, as the reducer answers for one machine.
    static let open = SidebarDocAcceptance(before: true, into: false, after: true)
    static let table: [String: SidebarDocAcceptance] = [
        "itm_p1": open, "itm_p2": open, pinned: SidebarDocAcceptance(before: false, into: true, after: false),
        "itm_other": open, machine: SidebarDocAcceptance(before: false, into: true, after: false),
    ]

    @Test func aWorkspaceFromTheListCannotLandBetweenPinnedWorkspaces() {
        let kept = Self.records().keepingPinned(Self.table, dragging: ["itm_loose"])
        for key in ["itm_p1", "itm_p2", Self.pinned] {
            #expect(kept[key] == SidebarDocAcceptance(before: false, into: false, after: false, refusal: "pinned_area"),
                    "a drop beside \(key) would pin the dragged workspace")
        }
        #expect(kept["itm_other"] == Self.open, "the list still takes it")
        #expect(kept[Self.machine] == Self.table[Self.machine])
    }

    @Test func aDragHoldingOneUnpinnedItemCannotLandInPinned() {
        let kept = Self.records().keepingPinned(Self.table, dragging: ["itm_p1", "itm_loose"])
        #expect(kept["itm_p2"]?.before == false && kept["itm_p2"]?.after == false)
    }

    /// A pinned group still takes workspaces from the list: into its header and between its members (the
    /// drop joins the group, it does not pin a loose row). Refused as `pinned_area`, a workspace could not be
    /// dragged into a pinned group at all; only the band's own top level stays closed.
    @Test func aWorkspaceFromTheListJoinsAPinnedGroup() {
        let group = SidebarDocItem(id: "itm_g_saved", section: Self.pinned, body: .group(name: "Saved", color: nil, icon: nil, collapsed: false))
        let member = SidebarDocItem(id: "itm_member", section: Self.pinned, parent: "itm_g_saved",
                                    body: .workspace(SidebarDocWorkspaceRef(sessionID: "s-local", workspaceID: "member")))
        var records = Self.records()
        records.items[group.id] = group
        records.items[member.id] = member
        let header = SidebarDocAcceptance(before: true, into: true, after: true)
        var table = Self.table
        table[group.id] = header
        table[member.id] = Self.open
        let kept = records.keepingPinned(table, dragging: ["itm_loose"])
        #expect(kept[group.id]?.into == true, "the pinned group's header refuses a drop into it")
        #expect(kept[group.id]?.before == false && kept[group.id]?.after == false, "beside the header is Pinned's top level")
        #expect(kept[member.id] == Self.open, "between the pinned group's members refuses a drop")
        #expect(kept["itm_p1"]?.before == false && kept[Self.pinned]?.into == false, "the band's top level stays closed")
    }

    @Test func pinnedWorkspacesStillReorderInPinned() {
        #expect(Self.records().keepingPinned(Self.table, dragging: ["itm_p1"]) == Self.table)
    }
}
