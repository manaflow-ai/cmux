import CmuxNextActions
import Testing
@testable import CmuxNextApp
@testable import CmuxNextTabs

/// R38 (Lawrence 2026-10-02): after a tab reorder, Ctrl-1/2/3 must select
/// the 1st/2nd/3rd tab the strip shows. Before, a reorder the daemon did
/// not apply (an app-local tab) left the strip showing its own order while
/// Ctrl-N read the model's.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct TabNumberAfterReorderTests {
    private func dragInStrip(_ strip: TabStripView, id: TabID, to index: Int) throws {
        let from = try #require(strip.displayed.firstIndex { $0.id == id })
        strip.drag = TabStripView.Drag(id: id, grabOffset: 0, originalIndex: from, currentIndex: index, isPinned: false,
                                       lastPoint: .zero, originalGroup: nil, targetGroup: nil)
        strip.endDrag()
    }

    private func expectNumbersSelectWhatTheStripShows(_ harness: ViewChangePermissionTests.Harness) async throws {
        let pane = try #require(harness.pane)
        let shown = pane.view.stripView.displayed.map(\.id)
        #expect(shown.count == 3)
        for number in 1...3 {
            try await ViewChangePermissionTests.run(harness, "selectSurfaceByNumber", origin: "user", focus: true,
                                                    arguments: ["index": .int(number)])
            #expect(pane.stripModel.selectedID == shown[number - 1], "Ctrl-\(number)")
        }
    }

    @Test func numbersFollowTheStripAfterAnAppLocalTabIsDragged() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let pane = try #require(harness.pane)
        try await ViewChangePermissionTests.run(harness, "openBrowser", origin: "cli", arguments: ["url": .string("https://example.com")])
        try await ViewChangePermissionTests.waitUntil { pane.view.stripView.displayed.count == 3 }
        let local = try #require(pane.view.stripView.displayed.last?.id)
        try dragInStrip(pane.view.stripView, id: local, to: 0)
        for _ in 0..<50 { await Task.yield() }
        try await expectNumbersSelectWhatTheStripShows(harness)
    }
}
