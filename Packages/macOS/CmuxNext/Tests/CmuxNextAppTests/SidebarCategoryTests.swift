@testable import CmuxNextSidebar
import Testing
import Foundation

struct SidebarCategoryTests {
    // The no-default switch in SidebarCategory.init is the exhaustiveness gate. This table
    // checks each semantic assignment, including the compatibility category for unfamiliar bodies.
    @Test func persistedKindsHaveTheirExpectedCategory() {
        let cases: [(SidebarDocBody, SidebarCategory)] = [
            (.workspace(.init(sessionID: "local", workspaceID: "ws")), .workspace),
            (.group(name: "Project", color: nil, icon: nil, collapsed: false), .group),
            (.builtin(SidebarBuiltIn.home.rawValue), .home),
            (.builtin(SidebarBuiltIn.settings.rawValue), .app),
            (.app("com.example.app"), .app), (.url("https://example.com", title: nil), .browserTab),
            (.tab("tab-1"), .browserTab), (.room("room-1"), .chat), (.savedGroup("saved"), .group),
            (.ref(kind: "custom", value: "item"), .custom), (.other("future"), .localMachine),
        ]
        for (body, category) in cases { #expect(SidebarCategory(body: body) == category) }
        #expect(SidebarCategory.lane(peer: "remote") == .fleetSession)
        #expect(SidebarCategory.lane(peer: nil) == .agentSession)
    }

    @Test func unfamiliarBodyPreservesLocalAndCustomPlacement() {
        let local = SidebarDocSection(id: "sec_m_local", kind: .machine(session: "local"))
        let custom = SidebarDocSection(id: "custom", kind: .custom)
        let items = [SidebarDocItem(id: "local-item", section: local.id, body: .other("future")),
                     SidebarDocItem(id: "custom-item", section: custom.id, body: .other("future"))]
        let rows = items.map { SidebarDocRow(key: $0.id, kind: "future", section: $0.section,
                                            depth: 0, item: $0.id) }
        let records = SidebarDocRecords(revision: 1, sections: [local.id: local, custom.id: custom],
                                        items: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }))
        let projection = SidebarDocProjection(rows: rows, records: records, revision: 1)
        #expect(projection.machines["local"]?.count == 1)
        if case let .link(item)? = projection.machines["local"]?.first {
            #expect(item.id == "local-item")
        } else { Issue.record("the existing local section must retain the unfamiliar item") }
        #expect(projection.layout.sections.first { $0.id == LayoutSectionID(custom.id) }?.items.map(\.id)
                == [LayoutItemID("custom-item")])
    }

    @Test func persistedItemRequiresExplicitPlacement() {
        let missingSection = Data(#"{"id":"future-item","body":{"type":"future"}}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SidebarDocWire.Item.self, from: missingSection)
        }
    }

}
