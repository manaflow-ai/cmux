import Foundation
@testable import CmuxNextSidebar
import Testing

/// Pinned reads one way (Leo 2026-11-22, "well fucking do the pin properly"): a row is
/// pinned when it sits in Pinned, at any depth, as a drag into Pinned and the row's Pin
/// both put it. A member pinned inside its group by an older app (`extra.pinned`) still
/// reads pinned, so its hover pin and menu read Unpin (plans/cmux-next/pinning-DESIGN.md).
@Suite struct SidebarDocPinInGroupTests {
    /// Machine section with group `g1` (members `w1` pinned in the group, `w2`), loose `w3`;
    /// Pinned holds `w4` and the pinned group `g2` (member `w5`).
    static let document = Data("""
    {"revision": "7",
     "sections": [
       {"id": "sec_m_s1", "kind": {"type": "machine", "session_id": "s1"}},
       {"id": "sec_pinned", "kind": {"type": "pinned"}}
     ],
     "items": [
       {"id": "g1", "section": "sec_m_s1", "order": "a", "body": {"type": "group", "name": "G"}},
       {"id": "w1", "section": "sec_m_s1", "parent": "g1", "order": "a",
        "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "ws_1"}}, "extra": {"pinned": true}},
       {"id": "w2", "section": "sec_m_s1", "parent": "g1", "order": "b",
        "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "ws_2"}}},
       {"id": "w3", "section": "sec_m_s1", "order": "b",
        "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "ws_3"}}, "extra": {"pinned": true}},
       {"id": "w4", "section": "sec_pinned", "order": "a",
        "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "ws_4"}},
        "extra": {"unpin_to": {"section": "sec_m_s1", "after": null}}},
       {"id": "g2", "section": "sec_pinned", "order": "b", "body": {"type": "group", "name": "P"}},
       {"id": "w5", "section": "sec_pinned", "parent": "g2", "order": "a",
        "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "ws_5"}}}
     ]}
    """.utf8)

    @Test func aMemberPinnedInItsGroupReadsPinned() throws {
        let records = try SidebarDocRecords(document: Self.document)
        #expect(records.items["w1"]?.pinnedInGroup == true)
        #expect(records.isPinned(item: "w1"), "Pin/Unpin on a member pinned in its group must read Unpin")
    }

    @Test func anUnpinnedMemberReadsUnpinned() throws {
        let records = try SidebarDocRecords(document: Self.document)
        #expect(!records.isPinned(item: "w2"))
    }

    @Test func theMarkCountsOnlyInsideAGroup() throws {
        let records = try SidebarDocRecords(document: Self.document)
        #expect(records.items["w3"]?.pinnedInGroup == false, "a stale mark on a loose row is not a pin")
        #expect(!records.isPinned(item: "w3"))
    }

    @Test func theBandsTopLevelReadsPinned() throws {
        let records = try SidebarDocRecords(document: Self.document)
        #expect(records.isPinned(item: "w4"))
        #expect(records.isPinned(item: "g2"))
    }

    @Test func aMemberOfAPinnedGroupReadsPinned() throws {
        // It sits in Pinned: its hover control reads Unpin, which takes it out, as dragging it out does.
        let records = try SidebarDocRecords(document: Self.document)
        #expect(records.isPinned(item: "w5"))
    }

    @Test func aBatchCarriesTheMark() throws {
        var records = try SidebarDocRecords(document: Self.document)
        let batch = Data("""
        {"changes": [{"kind": "state_upsert", "resource": "sidebar_item", "id": "w2",
          "value": {"id": "w2", "section": "sec_m_s1", "parent": "g1", "order": "a5",
                    "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "ws_2"}}, "extra": {"pinned": true}}}]}
        """.utf8)
        records.apply(batch: batch)
        #expect(records.isPinned(item: "w2"))
    }
}
