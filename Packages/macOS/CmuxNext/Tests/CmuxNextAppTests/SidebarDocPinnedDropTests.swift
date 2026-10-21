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

    @Test func pinnedWorkspacesStillReorderInPinned() {
        #expect(Self.records().keepingPinned(Self.table, dragging: ["itm_p1"]) == Self.table)
    }
}
