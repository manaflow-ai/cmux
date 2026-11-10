import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDaemon
import Foundation
import Testing

/// What ONE change in ONE workspace costs an observer that joins every workspace's items, in a session of 60 workspaces
/// and in the person's 826 (`CMUX_TEST_SESSION_SIZES=real`): the items its work visits (``ObservationWork``), never
/// only how many observers woke.
///
/// Why a count of the work: ``LargeSessionObservationTests`` counts wakes, and each of these observers passes it (one
/// tab's change wakes one workspace's observation). But the woken observer then asked `ObservedItems` for the items of
/// EVERY listed workspace and joined them all again, so one favicon change cost 826 key strings, 826 lookups and a join
/// of 826 lists on the main thread (SESSION 800, 2026-11-10: 198 of 4998 main-thread samples in `OpenTabFavicons.settle`
/// at 826, and the test times grew 14 to 20 times from 60 to 826). The rule (PATTERNS.md targeted observation): the work
/// after one item's change is O(changed + shown), so ``bound`` is ONE number for both sizes.
///
/// What the count sees: the models a list pass of `ObservedItems` visits, each map of a model, and the keys each
/// reader's join handles. Work that is not marked with ``ObservationWork`` is not counted, so this proves that the
/// named walks are gone, not that no other walk exists. Deterministic: no GUI, no timing.
@MainActor @Suite(.serialized)
struct ObservationCostTests {
    /// The most items one change of one workspace may visit: its own map (1 or 2 evaluations) and a join over what
    /// changed and what is shown (here at most 3 marked tabs or 1 site). The same at 60 and at 826 workspaces.
    static let bound = 8

    /// The models a list pass of `ObservedItems` has visited.
    private static func listed(_ work: ObservationWork) -> Int { work.byStep["ObservedItems.list"] ?? 0 }

    /// The models `ObservedItems` has mapped.
    private static func mapped(_ work: ObservationWork) -> Int { work.byStep["ObservedItems.map"] ?? 0 }

    /// `OpenTabFavicons` (the sidebar links' favicon table): a favicon change in one tab visits that tab's workspace and
    /// its site, whatever the session's size, and the table keeps its rule (the first open tab of a site in workspace
    /// order gives the favicon; a site whose first tab shows its own `/favicon.ico` is not in the table).
    @Test(.timeLimit(.minutes(2)), arguments: SessionFixtureSize.arms)
    func oneFaviconChangeVisitsItsWorkspaceOnly(size: SessionFixtureSize) async throws {
        let fixture = LargeSessionFixture(size)
        let work = ObservationWork()
        let openTabs = OpenTabFavicons()
        ObservationWork.$current.withValue(work) {
            openTabs.start(workspaces: { [store = fixture.store] in store.workspaces },
                           favicons: { workspace in OpenTabFavicons.favicons(of: workspace) { LargeSessionObservationTests.favicon($0) } })
        }
        await LargeSessionFixture.until { Self.listed(work) >= size.workspaces }
        try #require(Self.listed(work) >= size.workspaces, "fixture: the reader never read its workspace list")
        await LargeSessionFixture.drainMain()

        let pages = fixture.tabs().filter { $0.tab.kind == .browser && $0.tab.url?.hasSuffix("/cef") == true }
        try #require(pages.count == size.chromiumPages)
        // Every page of the fixture is of one site. Three of its Chromium pages, in workspace order.
        let origin = "http://127.0.0.1:9"
        let (early, middle, late) = (pages[1], pages[pages.count / 2], pages[pages.count - 2])
        func icon(_ workspace: Int) -> String { "\(origin)/\(workspace)/icon.png" }

        /// Makes one change, waits until the page's workspace was read again and the table shows `shows`, and checks
        /// what that one change visited.
        func step(_ name: String, shows: String?, _ change: () -> Void) async {
            work.reset()
            change()
            await LargeSessionFixture.until { Self.mapped(work) >= 1 && openTabs.byOrigin[origin] == shows }
            await LargeSessionFixture.drainMain()
            #expect(Self.mapped(work) >= 1, "fixture: no workspace was read again (the counter is not wired): \(name)")
            #expect(openTabs.byOrigin[origin] == shows, "\(name)")
            // The table kept from single changes is the table a join of every workspace gives (the reader before).
            let whole = OpenTabFavicons.table(fixture.store.workspaces.map { workspace in
                OpenTabFavicons.favicons(of: workspace) { LargeSessionObservationTests.favicon($0) }
            })
            #expect(openTabs.byOrigin == whole, "\(name): the table is not the join of every workspace")
            #expect(work.count <= Self.bound,
                    "\(name): one favicon change visited \(work.count) items \(work.byStep) in a session of \(size.workspaces) workspaces")
        }
        await step("a middle page gets a favicon", shows: icon(middle.workspace)) { middle.tab.faviconURL = icon(middle.workspace) }
        await step("an earlier page gets one: the first tab of the site wins", shows: icon(early.workspace)) {
            early.tab.faviconURL = icon(early.workspace)
        }
        await step("a later page gets one: the table stays", shows: icon(early.workspace)) { late.tab.faviconURL = icon(late.workspace) }
        await step("the earlier page loses its favicon: the next tab of the site gives it", shows: icon(middle.workspace)) {
            early.tab.faviconURL = nil
        }
        await step("the first tab shows the site's own favicon.ico: the site leaves the table", shows: nil) {
            middle.tab.faviconURL = origin + "/favicon.ico"
        }
    }

    /// `AttentionTabsWatch` (Needs you): an agent's mark on one tab visits that tab's workspace and the marked tabs (the
    /// list a person sees), whatever the session's size, and the list keeps its order (newest mark first).
    @Test(.timeLimit(.minutes(2)), arguments: SessionFixtureSize.arms)
    func oneAttentionMarkVisitsItsWorkspaceAndTheMarkedTabs(size: SessionFixtureSize) async throws {
        let fixture = LargeSessionFixture(size)
        let store = fixture.store
        store.session.apply(.snapshot(SessionStateMirror()), in: store)
        let work = ObservationWork()
        let tabs = AgentPaneAttentionTabs()
        var changes = 0
        let watch = ObservationWork.$current.withValue(work) {
            AttentionTabsWatch(tabs: tabs, machines: { [store] in [(machine: "local", store: store)] },
                               onChange: { _, _ in changes += 1 })
        }
        defer { withExtendedLifetime(watch) {} }
        await LargeSessionFixture.until { changes > 0 && Self.listed(work) >= size.workspaces }
        try #require(changes > 0 && Self.listed(work) >= size.workspaces, "fixture: the watch never read its workspace list")
        await LargeSessionFixture.drainMain()

        // An agent marks the first tab of one workspace (tab-attention-v1): a later workspace's mark is the newer one.
        func mark(_ workspace: Int) {
            let attention = TabAttention(reason: "Sign in \(workspace)", atMs: UInt64(1_000 + workspace),
                                         requestID: String(format: "%032llx", UInt64(workspace)))
            store.session.apply(.delta([.tab(ResourceID(rawValue: "tab_\(workspace)_0"), .init(attention: attention))]), in: store)
        }
        /// Makes one change of one tab's mark, waits until its workspace was read again and the list has `count` items,
        /// and checks what that one change visited and that the list is the join of every workspace (the watch before).
        func step(_ name: String, count: Int, _ change: () -> Void) async {
            work.reset()
            change()
            await LargeSessionFixture.until { Self.mapped(work) >= 1 && tabs.items.count == count }
            await LargeSessionFixture.drainMain()
            #expect(Self.mapped(work) >= 1, "fixture: no workspace was read again (the counter is not wired): \(name)")
            #expect(tabs.items.count == count, "\(name)")
            #expect(work.count <= Self.bound,
                    "\(name): one mark visited \(work.count) items \(work.byStep) in a session of \(size.workspaces) workspaces")
            let whole = AttentionTabsWatch.items(in: store.workspaces.map { ($0, machine: "local") })
            #expect(tabs.items == whole, "\(name): the list is not the join of every workspace")
        }
        let marked = [size.workspaces / 2, 2, size.workspaces - 1]
        for (index, workspace) in marked.enumerated() {
            await step("mark \(index + 1)", count: index + 1) { mark(workspace) }
        }
        #expect(tabs.items.map(\.reason) == marked.sorted(by: >).map { "Sign in \($0)" })
        // The person acted in one tab: its mark is gone (a tab record with no attention).
        await step("a mark is cleared", count: 2) {
            store.session.apply(.delta([.tab(ResourceID(rawValue: "tab_2_0"), .init())]), in: store)
        }
        #expect(tabs.items.map(\.reason) == [size.workspaces - 1, size.workspaces / 2].map { "Sign in \($0)" })
    }
}
