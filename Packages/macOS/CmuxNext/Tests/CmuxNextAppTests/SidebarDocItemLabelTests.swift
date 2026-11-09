import Foundation
@testable import CmuxNextSidebar
import Testing

/// An item's stored label (Rename on a link, a tab or an app) lives in the reducer's `extra.label`. The sidebar draws
/// items from the mirror's `project` reply, so the label is read from there: a pending rename shows at once, and a
/// confirmed one shows at all.
@MainActor @Suite struct SidebarDocItemLabelTests {
    @Test func theWireItemReadsTheLabelFromExtra() throws {
        let link = Data(#"{"id":"itm_l","section":"sec_pinned","body":{"type":"url","url":"https://a.example"},"extra":{"label":"Docs"}}"#.utf8)
        #expect(try JSONDecoder().decode(SidebarDocWire.Item.self, from: link).record.label == "Docs")
    }

    @Test func aPinnedLinksLabelDraws() throws {
        let pinned = "sec_pinned"
        let records = SidebarDocRecords(sections: [pinned: SidebarDocSection(id: pinned, kind: .pinned)], items: [
            "itm_l": SidebarDocItem(id: "itm_l", section: pinned, body: .url("https://a.example", title: nil), label: "Docs"),
        ])
        let rows = [SidebarDocRow(key: "itm_l", kind: "item", section: pinned, item: "itm_l")]
        let projection = SidebarDocProjection(rows: rows, records: records, revision: 1)
        let item = try #require(projection.layout.sections.first { $0.id.rawValue == pinned }?.items.first)
        #expect(item.label == "Docs")
    }
}
