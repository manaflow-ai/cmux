@testable import CmuxNextApp
import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextSidebar
import CmuxNextUpdater
import Foundation
import Testing

/// Lawrence 2026-10-18: "what's new should not show up in top left corner, ever. it should only
/// show up in the bottom left as a toast." After an update with unseen notes the sidebar gets no
/// What's New row at the top; the bottom-left "cmux Updated!" card shows once per version.
@MainActor
@Suite(.serialized)
struct WhatsNewPlacementTests {
    @Test func anUpdateWithUnseenNotesShowsOnlyTheBottomCardAndNoTopItem() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-whatsnew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"versions": ["1.0.0"]}"#.utf8).write(to: directory.appending(path: "index.json"))
        try Data(#"""
        {"schemaVersion": 1, "version": "1.0.0", "channel": "stable", "date": "2026-10-18",
         "headline": {"en": "New"},
         "entries": [{"id": "one", "category": "new", "title": {"en": "One"}, "summary": {"en": "One thing."},
                      "platforms": ["macos"], "audience": "all"}]}
        """#.utf8).write(to: directory.appending(path: "1.0.0.json"))
        let defaults = try #require(UserDefaults(suiteName: "cnc-whatsnew-\(UUID().uuidString)"))
        let source = BundledWhatsNewSource(directory: directory)

        let center = WhatsNewCenter(currentVersion: "1.0.0", defaults: defaults, sources: [source])
        await center.load().value
        #expect(center.debugPretendUpdated(from: "0.9.0"))
        #expect(!center.unseen.isEmpty, "the update has notes the user has not seen")
        #expect(center.showsUpdatedCard, "the bottom-left card shows after the update")

        let top = SidebarModel.topItems()
        #expect(!top.contains { $0.item.id.rawValue.contains("whats-new") }, "no What's New item at the top of the sidebar")

        center.dismissUpdated()
        #expect(!center.showsUpdatedCard)
        let relaunch = WhatsNewCenter(currentVersion: "1.0.0", defaults: defaults, sources: [source])
        await relaunch.load().value
        #expect(!relaunch.showsUpdatedCard, "once per version: a relaunch after the x shows no card")
    }
}
