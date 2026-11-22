@testable import CmuxNextSidebar
import Observation
import Testing

/// The switcher's window marks observe the windows only while the bar is in a window: a closed window's switcher
/// leaves no observer behind (#38281 F1, every observer has a stop condition).
@MainActor @Suite(.serialized) struct SpaceWindowMarksLifecycleTests {
    @Observable @MainActor final class Windows: SpaceWindowSource {
        var showing: [SpaceWindowShowing] = []
        func spaceWindowsShowing() -> [SpaceWindowShowing] { showing }
        func spaceWindowIsIncognito(_ windowID: String) -> Bool { false }
        func spaceWindowBringToFront(_ windowID: String) {}
        func spaceWindowBringHere(_ space: ProfileKey, window windowID: String) {}
        func spaceWindowNewIncognitoSpace() {}
    }

    /// Lets the marks' observation task run until `done` holds (at most `turns` main-actor turns).
    private func settle(turns: Int = 200, _ done: () -> Bool) async {
        for _ in 0..<turns where !done() { await Task.yield() }
    }

    @Test func theMarksFollowTheWindowsOnlyWhileActive() async {
        let windows = Windows()
        let marks = SpaceWindowMarks()
        let design = ProfileKey("design")
        marks.install(source: windows) { "here" }
        windows.showing = [SpaceWindowShowing(windowID: "other", space: design)]
        await settle(turns: 20) { false }
        #expect(marks.elsewhere.isEmpty, "inactive marks (the bar in no window) observe nothing")

        marks.isActive = true
        await settle { marks.elsewhere[design] != nil }
        #expect(marks.elsewhere[design]?.windowID == "other")

        marks.isActive = false
        windows.showing = []
        await settle(turns: 20) { false }
        #expect(marks.elsewhere[design]?.windowID == "other", "a closed window's marks stop following the windows")

        marks.isActive = true
        await settle { marks.elsewhere.isEmpty }
        #expect(marks.elsewhere.isEmpty, "back in a window, the marks read the windows again")
    }

    /// #38333 review: releasing active marks cancels their observation task (a dropped `Task` handle does not), so a
    /// switcher released without a teardown leaves no observer suspended on the windows.
    @Test func releasingActiveMarksCancelsTheirObservation() throws {
        let windows = Windows()
        var marks: SpaceWindowMarks? = SpaceWindowMarks()
        marks?.install(source: windows) { "here" }
        marks?.isActive = true
        let task = try #require(marks?.observation.withLock { $0 })
        #expect(!task.isCancelled)
        marks = nil
        #expect(task.isCancelled, "the released marks left their observation task running")
    }
}
