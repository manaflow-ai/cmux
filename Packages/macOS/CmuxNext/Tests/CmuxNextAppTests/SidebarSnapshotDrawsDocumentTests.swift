@testable import CmuxNextSidebar
import Foundation
import Testing

/// The launch video (c-9197de7242, frame 4): the apps after the list drew in the band below it until the sidebar
/// document came back, then moved into the list as a block (the band closed, the list grew 38 pt, its rows moved).
/// The saved sidebar now says whether the document drew, and a launch that expects it keeps the band closed.
@Suite
struct SidebarSnapshotDrawsDocumentTests {
    @Test func savesWhetherTheDocumentDrew() throws {
        let drew = SidebarSnapshot(sections: [SidebarSnapshot.Section](), profiles: [], activeProfileID: nil, drawsDocument: true)
        let back = try JSONDecoder().decode(SidebarSnapshot.self, from: JSONEncoder().encode(drew))
        #expect(back.drawsDocument == true)
        let plain = SidebarSnapshot(sections: [SidebarSnapshot.Section](), profiles: [], activeProfileID: nil)
        #expect(plain.drawsDocument == nil)
    }

    @Test func aSnapshotSavedBeforeTheFieldDrawsTheBand() throws {
        let old = Data(#"{"sections":[],"profiles":[]}"#.utf8)
        #expect(try JSONDecoder().decode(SidebarSnapshot.self, from: old).drawsDocument == nil)
    }

    @MainActor @Test func theModelSaysWhenItStopsWaiting() {
        let model = SidebarModel()
        var changes = 0
        model.onAwaitsDocumentChange = { changes += 1 }
        model.awaitsDocument = true
        model.awaitsDocument = true
        model.awaitsDocument = false
        #expect(changes == 2)
    }
}
