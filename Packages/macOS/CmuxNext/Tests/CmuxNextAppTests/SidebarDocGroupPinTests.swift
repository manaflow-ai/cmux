@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Testing

/// Pin Group on the sidebar document (https://github.com/manaflow-ai/cmux/issues/22259).
/// A group row's id is its document item: `itm_g_<id>` for a group from the
/// personal store (migrated or synced), the bare id for one the document
/// made. Pin/Unpin Group resolves the personal group, so it looked up
/// `itm_g_<id>` there and refused; and it sent the personal id back as the
/// item to pin, which the reducer does not know. The ids map both ways, and a
/// group in Pinned reads as pinned.
@Suite struct SidebarDocGroupPinTests {
    static let machineSection = "sec_m_s-local"

    static func records() -> SidebarDocRecords {
        let group = { (id: String, section: String) in
            SidebarDocItem(id: id, section: section, body: .group(name: id, color: nil, icon: nil, collapsed: false))
        }
        return SidebarDocRecords(items: [
            "itm_g_old": group("itm_g_old", machineSection),
            "grp_new": group("grp_new", SidebarDocStore.pinnedSection),
            "itm_w": SidebarDocItem(id: "itm_w", section: machineSection,
                                    body: .workspace(SidebarDocWorkspaceRef(sessionID: "s-local", workspaceID: "w"))),
        ])
    }

    @Test func aPersonalGroupFindsItsDocumentItem() {
        let records = Self.records()
        #expect(records.groupItem(personal: "old") == "itm_g_old", "a migrated or synced group is itm_g_<id>")
        #expect(records.groupItem(personal: "grp_new") == "grp_new", "a group the document made keeps its id")
        #expect(records.groupItem(personal: "missing") == nil)
        #expect(records.groupItem(personal: "itm_w") == nil, "a workspace item is no group")
    }

    @Test func aDocumentGroupItemNamesItsPersonalGroup() {
        #expect(PersonalStore.legacyGroupID(item: "itm_g_old") == WorkspaceGroupID(rawValue: "old"))
        #expect(PersonalStore.legacyGroupID(item: "grp_new") == nil, "a group the document made is looked up by its own id")
    }

    @Test func aGroupInPinnedReadsAsPinned() {
        let records = Self.records()
        #expect(records.isPinned(group: "grp_new"))
        #expect(!records.isPinned(group: "itm_g_old"))
        #expect(!records.isPinned(group: "missing"))
    }
}
