@testable import CmuxNextApp
import CmuxNextSidebar
import Testing

struct ChiefExperimentItemTests {
    @Test func insertsTheChiefFirstInTheHomeSectionOnlyWhenEnabled() {
        let layout = SidebarLayoutDocument.defaults
        #expect(ChiefExperimentItem.injected(into: layout, enabled: false) == layout)
        let injected = ChiefExperimentItem.injected(into: layout, enabled: true)
        let home = injected.section(SidebarLayoutDocument.topSectionID)
        #expect(home?.items.first?.id == ChiefExperimentItem.id)
        #expect(home?.items.first?.ref.kind == ChiefExperimentItem.kind)
        #expect(home?.items.dropFirst().map(\.id) == layout.section(SidebarLayoutDocument.topSectionID)?.items.map(\.id))
        // Applying it twice changes nothing (the layout observation runs on every store change).
        #expect(ChiefExperimentItem.injected(into: injected, enabled: true) == injected)
    }
}
