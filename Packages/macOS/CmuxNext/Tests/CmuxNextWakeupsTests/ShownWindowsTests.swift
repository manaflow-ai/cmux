@testable import CmuxNextWakeups
import Testing

/// ShownWindows: whether any tracked window is visible, told once per flip of
/// the whole set, never for a change that leaves it as it was.
@MainActor
@Suite("ShownWindows")
struct ShownWindowsTests {
    @Test func noWindowIsNothingShown() {
        #expect(!ShownWindows().anyShown)
    }

    @Test func itFlipsOnlyWhenTheLastWindowGoesOrTheFirstComes() {
        let shown = ShownWindows()
        let first = VisibilityNode(root: "first", own: .visible)
        let second = VisibilityNode(root: "second", own: .occluded)
        shown.track(first)
        shown.track(second)
        var told: [Bool] = []
        let observation = shown.observe { told.append($0) }

        second.set(.visible)
        first.set(.hidden)
        #expect(told.isEmpty, "a window still showed")
        second.set(.occluded)
        #expect(told == [false])
        #expect(!shown.anyShown)
        first.set(.visible)
        #expect(told == [false, true])
        observation.cancel()
        first.set(.hidden)
        #expect(told == [false, true], "a cancelled observation was told")
    }

    @Test func aHiddenAppHidesItsWindows() {
        let shown = ShownWindows()
        let app = VisibilityNode(root: "app", own: .visible)
        let window = VisibilityNode("window", own: .visible, parent: app)
        shown.track(window)
        #expect(shown.anyShown)
        app.set(.hidden)
        #expect(!shown.anyShown)
        app.set(.visible)
        #expect(shown.anyShown)
    }

    @Test func aClosedWindowStopsCountingAndAReleasedOneIsDropped() throws {
        let shown = ShownWindows()
        let app = VisibilityNode(root: "app", own: .visible)
        var window: VisibilityNode? = VisibilityNode("window", own: .visible, parent: app)
        shown.track(try #require(window))
        window?.detach()
        #expect(!shown.anyShown, "a detached window still showed")
        window = nil
        shown.track(VisibilityNode(root: "next", own: .hidden))
        #expect(shown.trackedCount == 1, "a released window stayed tracked")
    }

    @Test func aReleasedObservationIsNotTold() {
        let shown = ShownWindows()
        let window = VisibilityNode(root: "window", own: .visible)
        shown.track(window)
        var told = 0
        do {
            let observation = shown.observe { _ in told += 1 }
            #expect(observation.isActive)
        }
        window.set(.hidden)
        #expect(told == 0)
    }
}
