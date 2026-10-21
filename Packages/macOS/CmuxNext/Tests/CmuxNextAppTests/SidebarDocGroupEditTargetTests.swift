import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// #22996: Delete Group and Rename on the sidebar document said "The sidebar did not make this move". The daemon
/// lists a personal group (`grp_…`) as the item `itm_g_grp_…`; an op naming the personal id is refused
/// `unknown_item` (the CLI's `workspace group <id> delete` writes the personal row and worked). The document
/// below is a real `sidebar.get` of a daemon with one group and one member, shortened.
@MainActor @Suite
struct SidebarDocGroupEditTargetTests {
    static let document = #"""
    {"revision":"3","sections":[{"id":"sec_m_s1","kind":{"type":"machine","session_id":"s1"},"scroll":"flow"}],
     "items":[
      {"id":"itm_g_grp_1","section":"sec_m_s1","order":"W","shows_label":true,
       "body":{"type":"group","name":"tmpgrp","collapsed":false,"profile":"default"}},
      {"id":"itm_w_s1_ws_1","section":"sec_m_s1","parent":"itm_g_grp_1","order":"V","shows_label":true,
       "body":{"type":"workspace","ref":{"session_id":"s1","workspace_id":"ws_1"}}},
      {"id":"doc-made","section":"sec_m_s1","order":"X","shows_label":true,
       "body":{"type":"group","name":"made on the document","collapsed":true}}]}
    """#

    static func records() throws -> SidebarDocRecords { try SidebarDocRecords(document: Data(document.utf8)) }

    @Test func anEditNamedByThePersonalIDTargetsTheDocumentItem() throws {
        let records = try Self.records()
        #expect(SidebarDocStore.item(group: GroupID("grp_1"), in: records) == "itm_g_grp_1")
        #expect(SidebarDocStore.item(group: GroupID("itm_g_grp_1"), in: records) == "itm_g_grp_1")
    }

    @Test func aGroupTheDocumentMadeKeepsItsID() throws {
        let records = try Self.records()
        #expect(SidebarDocStore.item(group: GroupID("doc-made"), in: records) == "doc-made")
        // Not a group (a workspace item) or not in the document: the id goes as it is (the reducer judges it).
        #expect(SidebarDocStore.item(group: GroupID("itm_w_s1_ws_1"), in: records) == "itm_w_s1_ws_1")
        #expect(SidebarDocStore.item(group: GroupID("grp_gone"), in: records) == "grp_gone")
    }
}

/// New Subgroup named by a personal group id (CLI, automation) plans under that group's document item.
@MainActor @Suite
struct SidebarDocSubgroupPersonalParentTests {
    @Test func aPersonalParentIDPlansUnderItsDocumentItem() throws {
        let records = try SidebarDocGroupEditTargetTests.records()
        let plan = SidebarDocSubgroupPlan(parent: GroupID("grp_1"), id: GroupID("grp_new"), name: "sub", color: .green, records: records)
        #expect(plan.refusal == nil)
        let to = plan.ops?.first?["to"] as? [String: Any]
        #expect(to?["parent"] as? String == "itm_g_grp_1")
    }
}
