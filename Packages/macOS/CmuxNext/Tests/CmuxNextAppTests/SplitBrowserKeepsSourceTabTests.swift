import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// Split Browser Right/Down (Opt-Cmd-D) from an agent chat switched the chat's pane to the new browser tab, and then
/// showed the tab in the source before it moved to the split. Split Right (Cmd-D) shows its new pane in the key's turn
/// and never touches the source's tab. Split Browser now does the same: a stand-in pane with the browser shows in the
/// action's turn, the daemon's tab is made unselected and out of the source's strip, and once it moved the daemon's
/// pane takes the stand-in's place with the stand-in's page. A close of the stand-in cancels the split, a second press
/// on the stand-in splits the daemon's pane, and a failed move removes the stand-in and reports. Runs the person's
/// action against a same-tree cmux-tui, through the browser service's `create` seam.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitBrowserKeepsSourceTabTests {
    /// What each `create` asked for, and any tab the source pane's strip listed that it did not list before.
    private final class Seen {
        var activate: [Bool] = []
        var leaked: Set<String> = []
    }

    /// Holds the `create` seam until the test releases it.
    @MainActor private final class Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            open = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    /// The app's first pane, its controller, what its strip lists and selects, and the window's panes, before a split.
    private struct Fixture {
        let content: WorkspaceContentController
        let model: PaneModel
        let source: PaneController
        let selected: StripTabID?
        let listed: Set<String>
        let panes: Set<LayoutPaneID>

        @MainActor init(_ services: AppServices) async throws {
            content = try #require(services.windows.active?.workspaceContent)
            model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
            let source = try #require(services.paneController(for: model))
            try await PinnedPageTests.until({ source.stripModel.selectedID != nil }, report: { "fixture: the source pane selects no tab" })
            self.source = source
            selected = source.stripModel.selectedID
            listed = Set(source.stripModel.tabs.map(\.id.rawValue))
            panes = Set(content.panes.keys)
        }

        /// The new panes holding a daemon browser tab.
        @MainActor func landed() -> [PaneController] {
            content.panes.filter { pane in
                !panes.contains(pane.key) && pane.value.pane.tabs.contains { $0.kind == .browser && !ProvisionalTab.isProvisional($0.id) }
            }.map(\.value)
        }

        /// A new pane holding a stand-in browser tab, and that tab's id.
        @MainActor func standIn() -> (pane: PaneController, tab: String)? {
            for (key, pane) in content.panes where !panes.contains(key) {
                if let tab = pane.pane.tabs.first(where: { $0.kind == .browser && ProvisionalTab.isProvisional($0.id) }) { return (pane, tab.id) }
            }
            return nil
        }
    }

    /// Runs `action` as a person's key on pane `id`; returns its work and any refusal.
    private static func press(_ action: String, on id: String, _ services: AppServices) -> (work: [ActionWork], refusal: String?) {
        var work: [ActionWork] = []
        let refusal = services.registry.capturingRefusal {
            work = services.registry.capturingWork {
                _ = services.registry.perform(ActionID(rawValue: action), invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: id), origin: .user))
            }
        }
        return (work, refusal)
    }

    @Test(arguments: ["splitBrowserRight", "splitBrowserDown"])
    func theSplitShowsAtOnceAndTheSourceKeepsItsTab(action: String) async throws {
        try await PinnedPageTests.withApp { services, _ in
            let browserTabs = services.cache.browserTabs
            let create = browserTabs.create, seen = Seen(), gate = Gate()
            browserTabs.create = { daemon, pane, url, engine, profile, activate, after in
                seen.activate.append(activate)
                await gate.wait() // the daemon's tab is made once the stand-in's page exists
                return try await create(daemon, pane, url, engine, profile, activate, after)
            }
            let fixture = try await Fixture(services)
            let run = Self.press(action, on: fixture.model.id, services)
            try #require(run.refusal == nil, "the split was refused: \(run.refusal ?? "")")

            // In the action's turn: the new pane shows, holding the stand-in browser tab.
            let standIn = try #require(fixture.standIn(), "no stand-in pane with a browser tab showed in the action's turn")
            try await PinnedPageTests.until({ services.cache.existingBrowser(standIn.tab) != nil }, report: { "the stand-in made no page" })
            let page = try #require(services.cache.existingBrowser(standIn.tab).map { ObjectIdentifier($0.tab) })
            gate.release()

            try await PinnedPageTests.until({
                seen.leaked.formUnion(Set(fixture.source.stripModel.tabs.map(\.id.rawValue)).subtracting(fixture.listed))
                return fixture.landed().count == 1 && fixture.content.panes.count == fixture.panes.count + 1
            }, report: { "the daemon's pane did not take the stand-in's place: \(fixture.content.panes.values.map { $0.pane.tabs.map(\.id) })" })
            for task in run.work { #expect(await task.value == nil, "the split failed") }
            let tab = try #require(fixture.landed().first?.pane.tabs.first { $0.kind == .browser })
            #expect(seen.activate == [false], "the browser tab was made selected in the source pane: \(seen.activate)")
            #expect(seen.leaked.isEmpty, "the source pane's strip listed the browser tab: \(seen.leaked)")
            #expect(fixture.source.stripModel.selectedID == fixture.selected, "the source pane switched away from its tab")
            #expect(!fixture.source.pane.tabs.contains { $0.kind == .browser }, "the browser tab stayed in the source pane")
            #expect(fixture.standIn() == nil, "the stand-in stayed")
            // The stand-in's page is the daemon tab's: nothing reloaded at the swap.
            #expect(services.cache.existingBrowser(tab.id).map { ObjectIdentifier($0.tab) } == page, "the daemon's tab made a new page")
        }
    }

    /// Cmd-W on the stand-in before the daemon's pane lands cancels the split: no pane shows or takes the focus
    /// afterwards, and the made tab closes.
    @Test func closingTheStandInCancelsTheSplit() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let fixture = try await Fixture(services)
            let run = Self.press("splitBrowserRight", on: fixture.model.id, services)
            try #require(run.refusal == nil, "the split was refused: \(run.refusal ?? "")")
            let standIn = try #require(fixture.standIn(), "no stand-in pane showed")
            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: standIn.tab), origin: .user)))
            for task in run.work { #expect(await task.value == nil, "a cancelled split reported a failure") }
            @MainActor func browsers() -> Int { services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).count { $0.kind == .browser } }
            try await PinnedPageTests.until({ browsers() == 0 && services.daemon.store.pendingIntents.isEmpty },
                                            report: { "the cancelled split's tab stayed: \(browsers()) browser tabs, \(services.daemon.store.pendingIntents)" })
            #expect(fixture.content.panes.count == fixture.panes.count, "a pane stayed after the close")
            #expect(fixture.source.stripModel.selectedID == fixture.selected, "the source pane switched away from its tab")
        }
    }

    /// A second press while the first split's stand-in has the focus splits the daemon's pane that takes it over.
    @Test func aSecondPressOnTheStandInSplitsItsDaemonPane() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let fixture = try await Fixture(services)
            let first = Self.press("splitBrowserRight", on: fixture.model.id, services)
            let standIn = try #require(fixture.standIn(), "no stand-in pane showed")
            let second = Self.press("splitBrowserDown", on: standIn.pane.pane.id, services)
            try #require(first.refusal == nil && second.refusal == nil, "a split was refused: \(first.refusal ?? second.refusal ?? "")")
            // The second split's tab is made in the first split's daemon pane: its strip never lists it.
            var leaked = false
            try await PinnedPageTests.until({
                leaked = leaked || fixture.landed().contains { $0.stripModel.tabs.count > 1 }
                return fixture.landed().count == 2 && fixture.standIn() == nil
            }, report: { "two daemon panes did not land: \(fixture.content.panes.values.map { $0.pane.tabs.map(\.id) })" })
            for task in first.work + second.work { #expect(await task.value == nil, "a split failed") }
            #expect(!leaked, "the second split's tab showed in the first split's strip")
            #expect(!fixture.source.pane.tabs.contains { $0.kind == .browser }, "a browser tab stayed in the source pane")
        }
    }

    /// A move that fails removes the stand-in and its sizing, reports why, and leaves the source on its tab.
    @Test func aFailedMoveRemovesTheStandInAndReports() async throws {
        try await PinnedPageTests.withApp { services, _ in
            // A surface the daemon does not know: the move is refused.
            services.cache.browserTabs.create = { _, _, _, _, _, _, _ in SurfaceID(rawValue: 1 << 40) }
            let fixture = try await Fixture(services)
            let run = Self.press("splitBrowserRight", on: fixture.model.id, services)
            try #require(run.refusal == nil, "the split was refused: \(run.refusal ?? "")")
            #expect(fixture.standIn() != nil, "no stand-in pane showed")
            var failures: [String] = []
            for task in run.work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(failures.joined().contains("split-browser"), "no failure reported: \(failures)")
            try await PinnedPageTests.until({ fixture.standIn() == nil && fixture.content.panes.count == fixture.panes.count },
                                            report: { "the stand-in stayed after the failed move" })
            #expect(fixture.source.stripModel.selectedID == fixture.selected, "the source pane switched away from its tab")
        }
    }
}
