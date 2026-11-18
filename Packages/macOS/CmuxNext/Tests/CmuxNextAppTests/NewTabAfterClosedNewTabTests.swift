import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The tab of a New Tab key shows in the strip in the key's own call, directly after the tab that was selected. That
/// holds when the tab of an earlier New Tab key closed before the daemon answered its creation, and when another
/// creation of the pane has no answer yet.
///
/// Decision of 2026-11-16: the placement of a new tab ends when that tab closes, and no placement holds back a
/// stand-in tab (a stand-in is a creation of this window with a placement of its own). Before it, the placement of a
/// closed new tab stayed for 2 s at most, and in that time each New Tab key of the pane added no tab to the strip.
///
/// A whole window of the `large` session with no daemon. No creation is answered before a test's checks end, and
/// each test presses its keys in one turn of the main actor: no wait, and nothing of a daemon comes in between.
/// Limit: on a machine that stalls for the placement's own limit between two keys (500 ms in the second test, 2 s in
/// the first), the placement is past its limit and the test passes with and without the mend.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct NewTabAfterClosedNewTabTests {
    /// The creations of one test: each waits here, so none is answered before `release()`.
    @MainActor private final class HeldCreations {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func wait() async {
            if released { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            released = true
            for one in waiting { one.resume() }
            waiting = []
        }
    }

    /// The pane of a test and its strip at the start.
    private struct Start {
        let pane: PaneController
        let services: AppServices
        /// The strip's tab ids, and the index of the selected one (never the last).
        let strip: [String]
        let selected: Int

        /// The strip of the start with `tab` directly after the tab that was selected.
        func with(_ tab: String) -> [String] {
            var strip = strip
            strip.insert(tab, at: selected + 1)
            return strip
        }
    }

    /// Runs `body` on the focused pane of a whole window. The New Tab key makes a New Tab page there, and the
    /// daemon's side of its creation waits until `body` ends.
    private static func withPane(_ body: @MainActor (Start) throws -> Void) async throws {
        // An inert address for each New Tab page: the pages load nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        try await LargeSessionWindowFixture.withController(.large, agentPaneEnvironment: environment) { _, controller in
            let services = controller.services
            let tabs = services.agentTabs
            try #require(tabs.canHostChat, "setup: this build has no New Tab page")
            let pane = try #require(controller.focusedPane, "setup: the window has no focused pane")
            let held = HeldCreations()
            tabs.localHost = AgentSessionRef.host(installID: "new-tab-after-closed-new-tab")
            tabs.holdsTabs = { _ in true }
            tabs.reachable = { _ in true }
            tabs.create = { _, _, _, _, _, _ in
                await held.wait()
                throw CancellationError()
            }
            let strip = pane.orderedIDs.map(\.rawValue)
            let records = pane.pane.tabs.map(\.id)
            try #require(strip == records, "setup: the strip \(strip) is not the store's list \(records)")
            let selectedID = try #require(pane.stripModel.selectedID?.rawValue, "setup: the pane selects no tab")
            let selected = try #require(strip.firstIndex(of: selectedID), "setup: the selected tab is not in the strip")
            // A new tab after the pane's last tab is in its place as the store lists it: it has no placement to test.
            try #require(selected + 1 < strip.count, "setup: the selected tab is the pane's last")
            var failure: (any Error)?
            do { try body(Start(pane: pane, services: services, strip: strip, selected: selected)) } catch { failure = error }
            // Each creation ends before the window closes.
            held.release()
            await LargeSessionWindowFixture.drainMain()
            if let failure { throw failure }
        }
    }

    /// One New Tab key. `made`: the tabs that the strip lists more than before the key, read in the key's own call.
    private static func newTab(_ start: Start) -> (ran: Bool, made: [String]) {
        let before = Set(start.pane.orderedIDs.map(\.rawValue))
        let ran = start.services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user))
        return (ran, start.pane.orderedIDs.map(\.rawValue).filter { !before.contains($0) })
    }

    private static func strip(_ start: Start) -> [String] { start.pane.orderedIDs.map(\.rawValue) }
    private static func selected(_ start: Start) -> String { start.pane.stripModel.selectedID?.rawValue ?? "none" }

    /// New Tab, Close Tab on that tab, New Tab: the second new tab shows at once, in the place of the first.
    @Test func aNewTabAfterTheCloseOfANewTabShowsAtOnceInItsPlace() async throws {
        try await Self.withPane { start in
            let first = Self.newTab(start)
            try #require(first.ran && first.made.count == 1,
                         "setup: the first New Tab key \(first.ran ? "ran" : "was refused") and the strip has \(first.made.count) new tabs")
            try #require(Self.strip(start) == start.with(first.made[0]),
                         "setup: the first new tab is not directly after the selected tab: \(Self.strip(start))")
            try #require(Self.selected(start) == first.made[0], "setup: the first new tab is not selected")

            try #require(start.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)),
                         "setup: Close Tab was refused")
            try #require(Self.strip(start) == start.strip, "setup: the strip after the close is not the strip of the start: \(Self.strip(start))")
            try #require(Self.selected(start) == start.strip[start.selected],
                         "setup: the close selects \(Self.selected(start)), not the tab that was selected at the start")

            let second = Self.newTab(start)
            #expect(second.ran, "the second New Tab key was refused")
            #expect(second.made.count == 1, "the second New Tab key added \(second.made.count) tabs to the strip in its own call, want 1")
            guard let made = second.made.first, second.made.count == 1 else { return }
            let strip = Self.strip(start), want = start.with(made)
            #expect(strip == want, "the strip lists \(strip), want \(want): the new tab directly after the selected tab")
            #expect(Self.selected(start) == made, "the pane selects \(Self.selected(start)), want the new tab \(made)")
        }
    }

    /// Another creation of the pane has a placement and no answer (a duplicate, a link's tab), then New Tab: the new
    /// tab shows at once. The first line starts that placement by the strip's own type, so this test goes away with
    /// that type; the test above names no type of the strip.
    @Test func aNewTabShowsAtOnceWhileAnotherCreationOfThePaneHasNoAnswer() async throws {
        try await Self.withPane { start in
            try #require(NewTabSuccession.begin(after: nil, in: start.pane.pane, services: start.services) != nil,
                         "setup: the other creation's placement did not start")
            let key = Self.newTab(start)
            #expect(key.ran, "the New Tab key was refused")
            #expect(key.made.count == 1, "the New Tab key added \(key.made.count) tabs to the strip in its own call, want 1")
            guard let made = key.made.first, key.made.count == 1 else { return }
            let strip = Self.strip(start), want = start.with(made)
            #expect(strip == want, "the strip lists \(strip), want \(want): the new tab directly after the selected tab")
            #expect(Self.selected(start) == made, "the pane selects \(Self.selected(start)), want the new tab \(made)")
        }
    }
}
