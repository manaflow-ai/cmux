@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import Testing

/// The opener relations the tab close successor reads
/// (`BrowserTabOpeners.relations`, `FocusAfterClose.liveOpeners` and `.tab`;
/// manaflow-ai/cmux#21805 row 1).
@MainActor
struct BrowserTabOpenersCloseFocusTests {
    private static func open(_ child: SurfaceID, from opener: SurfaceID, _ openers: BrowserTabOpeners, order: [SurfaceID]) async throws {
        _ = try await openers.place(opener: opener, foreground: false, order: { order }) { _ in child }
    }

    private static func relations(_ openers: BrowserTabOpeners, among order: [SurfaceID]) -> [SurfaceID: SurfaceID] {
        FocusAfterClose.liveOpeners(openers.openerOf, among: order)
    }

    private static func pick(_ closed: SurfaceID, in old: [SurfaceID], _ openers: BrowserTabOpeners) -> SurfaceID? {
        let surviving = old.filter { $0 != closed }
        return FocusAfterClose.tab(selected: closed, old: old, surviving: surviving, shown: Set(surviving),
                                   opener: relations(openers, among: old))
    }

    @Test func aClosedLinkTabGoesBackToItsOpener() async throws {
        let openers = BrowserTabOpeners()
        try await Self.open(2, from: 1, openers, order: [1, 3])
        #expect(Self.relations(openers, among: [1, 2, 3]) == [2: 1])
        #expect(Self.pick(2, in: [1, 2, 3], openers) == 1)
    }

    @Test func anUnrelatedSwitchForgetsTheOpener() async throws {
        let openers = BrowserTabOpeners()
        try await Self.open(2, from: 1, openers, order: [1, 3])
        // Moving between a child and its opener keeps the relation.
        openers.userActivated(from: 1, to: 2)
        #expect(Self.relations(openers, among: [1, 2, 3]) == [2: 1])
        // A switch to an unrelated tab and back forgets it: Cmd-W then takes the right neighbor.
        openers.userActivated(from: 2, to: 3)
        openers.userActivated(from: 3, to: 2)
        #expect(Self.relations(openers, among: [1, 2, 3]).isEmpty)
        #expect(Self.pick(2, in: [1, 2, 3], openers) == 3)
    }

    @Test func aTabWhoseOpenerClosedTakesTheOpenersOpener() async throws {
        let openers = BrowserTabOpeners()
        try await Self.open(2, from: 1, openers, order: [1])
        try await Self.open(3, from: 2, openers, order: [1, 2])
        // Tab 2 is gone: 3's opener is 1, as Chrome's FixOpeners would make it.
        #expect(Self.relations(openers, among: [1, 3, 4]) == [3: 1])
        #expect(Self.pick(3, in: [1, 3, 4], openers) == 1)
    }
}
