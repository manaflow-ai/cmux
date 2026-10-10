import CmuxNextHistory
import Foundation
import Testing

/// The location trail reducer (plans/cmux-next/history.md 4.2).
struct LocationTrailTests {
    static func loc(_ tab: String, machine: String = "home", window: String = "w1", incognito: Bool = false) -> HistoryLocation {
        HistoryLocation(key: .init(machine: machine, tab: tab), window: window, workspace: "ws", pane: "p-\(tab)",
                        content: .terminal, title: tab.uppercased(), isIncognito: incognito)
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Records tabs one per 2 s (never coalesced).
    static func trail(_ tabs: [String]) -> LocationTrail {
        var trail = LocationTrail()
        for (index, tab) in tabs.enumerated() { trail.record(loc(tab), at: at(Double(index) * 2)) }
        return trail
    }

    static func tabs(_ trail: LocationTrail) -> [String] { trail.entries.map(\.location.key.tab) }

    @Test func recordsDistinctLocationsInOrder() {
        let trail = Self.trail(["a", "b", "c"])
        #expect(Self.tabs(trail) == ["a", "b", "c"])
        #expect(trail.current?.location.key.tab == "c")
    }

    @Test func sameTabTwiceIsOneEntryButRefreshesContext() {
        var trail = Self.trail(["a"])
        var renamed = Self.loc("a")
        renamed.title = "renamed"
        let step1 = trail.record(renamed, at: Self.at(10))
        #expect(!step1 || trail.entries.count == 1)
        #expect(trail.entries.count == 1)
        #expect(trail.current?.location.title == "renamed")
    }

    @Test func quickSweepCoalescesIntoWhereTheUserStopped() {
        var trail = Self.trail(["a"])
        trail.record(Self.loc("b"), at: Self.at(5))
        trail.record(Self.loc("c"), at: Self.at(5.2))
        trail.record(Self.loc("d"), at: Self.at(5.4))
        #expect(Self.tabs(trail) == ["a", "d"])
    }

    @Test func sweepBackToThePreviousLocationDropsTheTransientEntry() {
        var trail = Self.trail(["a"])
        trail.record(Self.loc("b"), at: Self.at(5))
        trail.record(Self.loc("a"), at: Self.at(5.3))
        #expect(Self.tabs(trail) == ["a"])
        #expect(trail.current?.location.key.tab == "a")
    }

    @Test func abaIsARealPathWhenTheUserDwells() {
        let trail = Self.trail(["a", "b", "a"])
        #expect(Self.tabs(trail) == ["a", "b", "a"])
    }

    @Test func backAndForwardMoveTheCursorAndMarkPending() throws {
        var trail = Self.trail(["a", "b", "c"])
        let backStep = trail.back()

        let back = try #require(backStep)
        #expect(back.location.key.tab == "b")
        #expect(trail.pending == back.location.key)
        #expect(trail.canGoBack() && trail.canGoForward())
        // The focus the navigation causes is absorbed, not recorded.
        let step2 = trail.record(Self.loc("b"), at: Self.at(100))
        #expect(!step2 || Self.tabs(trail) == ["a", "b", "c"])
        #expect(Self.tabs(trail) == ["a", "b", "c"])
        #expect(trail.pending == nil)
        let forwardStep = trail.forward()

        let forward = try #require(forwardStep)
        #expect(forward.location.key.tab == "c")
        #expect(!trail.canGoForward())
    }

    @Test func absorbedNavigationIsNeverCoalescedAway() throws {
        var trail = Self.trail(["a", "b", "c"])
        let step3 = trail.back()
        #expect(step3 != nil)
        trail.record(Self.loc("b"), at: Self.at(100))
        // A quick move right after landing keeps the landed entry.
        trail.record(Self.loc("x"), at: Self.at(100.1))
        #expect(Self.tabs(trail) == ["a", "b", "x"])
    }

    @Test func recordingAfterBackDropsTheForwardEntries() throws {
        var trail = Self.trail(["a", "b", "c", "d"])
        _ = trail.back()
        trail.record(Self.loc("c"), at: Self.at(50))
        _ = trail.back()
        trail.record(Self.loc("b"), at: Self.at(60))
        trail.record(Self.loc("x"), at: Self.at(70))
        #expect(Self.tabs(trail) == ["a", "b", "x"])
        #expect(!trail.canGoForward())
    }

    @Test func aDifferentSettledLocationClearsPendingAndRecords() throws {
        var trail = Self.trail(["a", "b", "c"])
        let step4 = trail.back()
        #expect(step4 != nil)
        trail.record(Self.loc("z"), at: Self.at(50))
        #expect(trail.pending == nil)
        #expect(Self.tabs(trail) == ["a", "b", "z"])
    }

    @Test func backSkipsUnavailableEntriesWithoutDroppingThem() throws {
        var trail = Self.trail(["a", "b", "c"])
        let entryStep = trail.back { $0.key.tab != "b" }

        let entry = try #require(entryStep)
        #expect(entry.location.key.tab == "a")
        #expect(Self.tabs(trail) == ["a", "b", "c"])
        #expect(!trail.canGoBack { $0.key.tab != "b" })
        let step5 = trail.forward { $0.key.tab != "b" }
        #expect(step5?.location.key.tab == "c")
    }

    @Test func nothingToGoBackToReturnsNil() {
        var trail = Self.trail(["a"])
        let step6 = trail.back()
        #expect(step6 == nil)
        let step7 = trail.forward()
        #expect(step7 == nil)
        var empty = LocationTrail()
        let step8 = empty.back()
        #expect(step8 == nil)
        let step9 = empty.last()
        #expect(step9 == nil)
    }

    @Test func lastTogglesBetweenTwoLocations() throws {
        var trail = Self.trail(["a", "b", "c"])
        let step10 = trail.last()
        #expect(step10?.location.key.tab == "b")
        trail.record(Self.loc("b"), at: Self.at(50))
        let step11 = trail.last()
        #expect(step11?.location.key.tab == "c")
        trail.record(Self.loc("c"), at: Self.at(60))
        let step12 = trail.last()
        #expect(step12?.location.key.tab == "b")
    }

    @Test func capacityDropsTheOldestAndKeepsTheCursorOnTheSameEntry() {
        var trail = LocationTrail(capacity: 3)
        for (index, tab) in ["a", "b", "c", "d", "e"].enumerated() { trail.record(Self.loc(tab), at: Self.at(Double(index) * 2)) }
        #expect(Self.tabs(trail) == ["c", "d", "e"])
        #expect(trail.current?.location.key.tab == "e")
        #expect(trail.cursor == 2)
    }

    @Test func removeAllKeepsTheCursorOnASurvivor() throws {
        var trail = Self.trail(["a", "b", "c", "d"])
        _ = trail.back()
        trail.record(Self.loc("c"), at: Self.at(50))
        trail.removeAll { $0.location.key.tab == "c" }
        #expect(Self.tabs(trail) == ["a", "b", "d"])
        #expect(trail.current?.location.key.tab == "b")
        trail.removeAll { _ in true }
        #expect(trail.entries.isEmpty && trail.cursor == -1 && trail.current == nil)
    }

    @Test func refreshUpdatesEveryEntryOfTheTab() {
        var trail = Self.trail(["a", "b", "a"])
        var moved = Self.loc("a", window: "w2")
        moved.title = "moved"
        trail.refresh(moved)
        #expect(trail.entries.filter { $0.location.key.tab == "a" }.allSatisfy { $0.location.window == "w2" && $0.location.title == "moved" })
        #expect(trail.entries[1].location.title == "B")
    }

    @Test func persistableDropsIncognitoEntries() {
        var trail = LocationTrail()
        trail.record(Self.loc("a"), at: Self.at(0))
        trail.record(Self.loc("secret", incognito: true), at: Self.at(2))
        trail.record(Self.loc("b"), at: Self.at(4))
        let saved = trail.persistable
        #expect(Self.tabs(saved) == ["a", "b"])
        #expect(saved.current?.location.key.tab == "b")
    }

    @Test func machinesQualifyIdentity() {
        var trail = LocationTrail()
        trail.record(Self.loc("t1", machine: "home"), at: Self.at(0))
        trail.record(Self.loc("t1", machine: "build-box"), at: Self.at(2))
        #expect(trail.entries.count == 2)
    }

    @Test func roundTripsThroughJSON() throws {
        var trail = Self.trail(["a", "b", "c"])
        _ = trail.back()
        let data = try JSONEncoder().encode(trail)
        let decoded = try JSONDecoder().decode(LocationTrail.self, from: data)
        #expect(Self.tabs(decoded) == ["a", "b", "c"])
        #expect(decoded.cursor == trail.cursor)
    }
}
