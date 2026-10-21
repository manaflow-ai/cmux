@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextBridge
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

    /// `relations(among:)` maps the surface tree onto the pane's tab ids; an
    /// opener outside the given tabs (another pane) is not reported.
    @Test func relationsMapSurfacesToTabIDs() async throws {
        let openers = BrowserTabOpeners()
        try await Self.open(2, from: 1, openers, order: [1, 3])
        try await Self.open(4, from: 3, openers, order: [1, 2, 3])
        let tabs = ([1, 2, 3, 4] as [SurfaceID]).map { TabModel(TabSnapshot(surface: $0, kind: .browser)) }
        #expect(openers.relations(among: tabs) == [tabs[1].id: tabs[0].id, tabs[3].id: tabs[2].id])
        // Tab 3 shows in another pane: 4 inherits nothing from this pane, 2 keeps 1.
        #expect(openers.relations(among: [tabs[0], tabs[1], tabs[3]]) == [tabs[1].id: tabs[0].id])
    }

    /// The apply that picks a closed tab's successor no longer lists it (TabCloseOverlay); the
    /// pane's previous apply did, also before the first close in that pane. Two windows show the
    /// pane, each with its own selection and last tabs: the close goes back to the opener in both.
    @Test func aClosedLinkTabsSuccessorIsItsOpenerInEveryWindow() async throws {
        let openers = BrowserTabOpeners()
        let tabs = ([1, 2, 3] as [SurfaceID]).map { TabModel(TabSnapshot(surface: $0, kind: .browser)) }
        let windows = [TabSelectionMemory(), TabSelectionMemory()]
        var last: [[(SurfaceID, String)]] = [[], []]
        func apply(_ shown: [TabModel], in window: Int) -> String? {
            windows[window].resolve(pane: "p", tabs: shown.map(\.id), defaultIndex: 0,
                                    openers: openers.closeRelations(among: shown, last: &last[window]))
        }
        for window in 0..<2 { _ = apply([tabs[0], tabs[2]], in: window) }
        try await Self.open(2, from: 1, openers, order: [1, 3])
        for window in 0..<2 {
            _ = apply(tabs, in: window)
            windows[window].select(tabs[1].id, in: "p")
            _ = apply(tabs, in: window)
        }
        #expect(apply([tabs[0], tabs[2]], in: 0) == tabs[0].id)
        #expect(apply([tabs[0], tabs[2]], in: 1) == tabs[0].id)
    }
}
