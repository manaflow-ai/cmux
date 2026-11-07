import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// Leo 2026-11-03: "it's so slow to open and close ... it's nigh instant for claude and codex so we
/// nede to be at least as fast"; 2026-10-25: closing the right pane waited for its tab's close. A
/// person's close of a live Chromium tab ran the page's beforeunload first (`BrowserUserClosing`)
/// and left the tab, and for a pane's last tab the pane, on screen until the renderer answered.
/// Chrome takes the tab away at once and brings it back only if the page asks. The page that
/// decides is the injected `pageDecidesClose`; its own close (no handler, or Leave) is the
/// `closeTab` on the tab that BrowserPageRequests runs. Through the app against a same-tree daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct BrowserTabCloseLeavesAtOnceTests {
    /// The closed tab leaves its strip in the click's turn; the page's close then closes it for real.
    @Test func aDecidingPagesTabLeavesTheStripInTheClicksTurn() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(services.windows.active?.focusedPane)
            let handle = pane.pane.handle
            let kept = try await connection.newFrontendBrowserTab(url: "https://example.com/kept", engine: .webkit, in: handle, activate: false)
            let closed = try await connection.newFrontendBrowserTab(url: "https://example.com/form", engine: .webkit, in: handle, activate: false)
            try await PinnedPageTests.until({ [kept, closed].allSatisfy { store.tab(surface: $0.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true } })
            let id = try #require(store.tab(surface: closed.surface)).id
            let undo = try #require(services.closedTabs?.undoToasts)
            var deciding: Set<String> = [id]
            undo.pageDecidesClose = { _, tab in deciding.contains(tab.rawValue) }

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user)))
            #expect(!pane.orderedIDs.map(\.rawValue).contains(id), "the closed tab waits in its strip for its page: \(pane.orderedIDs.map(\.rawValue))")

            // The page closes (no beforeunload handler): its tab closes for real.
            deciding.remove(id)
            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id))))
            try await PinnedPageTests.until({ store.liveTreeLists(tab: id) == false }, within: .seconds(10),
                                            report: { "the page's close did not close its tab: \(store.pane(handle)?.tabs.map(\.id) ?? [])" })
            #expect(!pane.orderedIDs.map(\.rawValue).contains(id))
            #expect(store.tab(surface: kept.surface) != nil, "the other tab closed")
        }
    }

    /// The page's own close comes as its `.close` request (`BrowserPageRequests`, as `CEFTab.browserDidClose`
    /// sends it), not a `closeTab` on the tab: the hidden tab is found and closed then, at once, not at the deadline.
    /// Review of #32876 at 9b3becab797: the hidden tab was out of the store's index, so the request was dropped.
    @Test func thePagesOwnCloseRequestClosesItsHiddenTabAtOnce() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(services.windows.active?.focusedPane)
            let handle = pane.pane.handle
            let kept = try await connection.newFrontendBrowserTab(url: "https://example.com/kept", engine: .webkit, in: handle, activate: false)
            let closed = try await connection.newFrontendBrowserTab(url: "https://example.com/form", engine: .webkit, in: handle, activate: true)
            try await PinnedPageTests.until({ [kept, closed].allSatisfy { store.tab(surface: $0.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true } })
            let id = try #require(store.tab(surface: closed.surface)).id
            pane.select(StripTabID(id))
            try await PinnedPageTests.until({ services.cache.browsers[id] != nil }, report: { "the page of \(id) was never made" })
            let page = try #require(services.cache.browsers[id]?.tab)
            let undo = try #require(services.closedTabs?.undoToasts)
            var deciding: Set<String> = [id]
            undo.pageDecidesClose = { _, tab in deciding.contains(tab.rawValue) }

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user)))
            try #require(!pane.orderedIDs.map(\.rawValue).contains(id) && undo.hiddenPages.contains(id))
            deciding.remove(id)
            let start = ContinuousClock.now
            services.cache.pageRequests.browserTab(page, didRequest: .close)
            #expect(!undo.hiddenPages.contains(id), "the page's close request left its tab hidden")
            try await PinnedPageTests.until({ store.liveTreeLists(tab: id) == false }, within: .seconds(4),
                                            report: { "the page's close request did not close its tab: \(store.pane(handle)?.tabs.map(\.id) ?? [])" })
            #expect(start.duration(to: .now) < .seconds(4), "closed only at the hide's deadline")
            #expect(store.tab(surface: kept.surface) != nil, "the other tab closed")
        }
    }

    /// Both tabs of a split pane are deciding pages, closed in one gesture: the pane leaves at once, and when the pages
    /// close (their `.close` requests) the gesture is still ONE Reopen Closed step. Review of #32876 at 66aaa5601f8: the
    /// emptied pane had no controller shown, so each page's close went to the daemon alone, outside the gesture.
    @Test func closingAnEmptiedPanesDecidingPagesIsOneReopenStep() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let window = try #require(services.windows.active)
            let first = try #require(window.workspaceContent?.panes.values.first?.pane)
            _ = try await connection.split(first.handle, direction: .right)
            let screenPanes = { store.workspaces.flatMap(\.screens).first { $0.panes.contains { $0 === first } }?.panes ?? [] }
            try await PinnedPageTests.until({ screenPanes().count == 2 && screenPanes().allSatisfy { !$0.tabs.isEmpty } && window.workspaceContent?.panes.count == 2 },
                                            within: .seconds(30), report: { "\(screenPanes().count) panes" })
            let right = try #require(screenPanes().first { $0 !== first })
            var ids: [String] = []
            for name in ["a", "b"] {
                let page = try await connection.newFrontendBrowserTab(url: "https://example.com/\(name)", engine: .webkit, in: right.handle, activate: true)
                try await PinnedPageTests.until({ store.tab(surface: page.surface) != nil })
                ids.append(try #require(store.tab(surface: page.surface)).id)
            }
            for tab in right.tabs where !ids.contains(tab.id) {
                #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .cli)))
            }
            let controller = try #require(services.paneController(for: right))
            try await PinnedPageTests.until({ Set(controller.orderedIDs.map(\.rawValue)) == Set(ids) }, report: { "\(controller.orderedIDs)" })
            var pages: [any BrowserTab] = []
            for id in ids {
                controller.select(StripTabID(id))
                try await PinnedPageTests.until({ services.cache.browsers[id] != nil }, report: { "the page of \(id) was never made" })
                pages.append(try #require(services.cache.browsers[id]?.tab))
            }
            let layout = try #require(controller.workspace?.layoutModel)
            let paneID = controller.layoutPaneID
            let undo = try #require(services.closedTabs?.undoToasts)
            var deciding = Set(ids)
            undo.pageDecidesClose = { _, tab in deciding.contains(tab.rawValue) }
            let seen = Set(store.closedItems.map(\.id))

            CloseUndoToasts.close(in: controller, ids.map { StripTabID($0) })
            #expect(layout.isClosing(paneID), "the emptied pane waits on screen for its pages")
            // The pages close, one after the other, as Chromium reports them.
            deciding = []
            for page in pages { services.cache.pageRequests.browserTab(page, didRequest: .close) }
            try await PinnedPageTests.until({ ids.allSatisfy { store.liveTreeLists(tab: $0) == false } }, within: .seconds(10),
                                            report: { "open: \(ids.filter { store.liveTreeLists(tab: $0) != false })" })
            let fresh = { store.closedItems.filter { !seen.contains($0.id) } }
            try await PinnedPageTests.until({ fresh().flatMap(\.tabs).count >= 2 }, report: { "closed: \(fresh().map { ($0.id, $0.tabs.count) })" })
            #expect(fresh().count == 1, "one gesture stored \(fresh().count) Reopen Closed steps: \(fresh().map(\.tabs.count))")
        }
    }

    /// A split pane holds a deciding page A and a tab B. Close A (hidden), then B: B's close takes the pane out. When A then
    /// asks, the pane and A come back, selected, before the question. Review of #32876 at 7e046b696d8: A's hide held no
    /// pane close (B still showed), so its restore left the pane B's close had hidden, with A's question behind it.
    @Test func aPageThatAsksAfterALaterCloseEmptiedItsPaneBringsThePaneBack() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let window = try #require(services.windows.active)
            let first = try #require(window.workspaceContent?.panes.values.first?.pane)
            _ = try await connection.split(first.handle, direction: .right)
            let screenPanes = { store.workspaces.flatMap(\.screens).first { $0.panes.contains { $0 === first } }?.panes ?? [] }
            try await PinnedPageTests.until({ screenPanes().count == 2 && screenPanes().allSatisfy { !$0.tabs.isEmpty } && window.workspaceContent?.panes.count == 2 },
                                            within: .seconds(30), report: { "\(screenPanes().count) panes" })
            let right = try #require(screenPanes().first { $0 !== first })
            let a = try await connection.newFrontendBrowserTab(url: "https://example.com/a", engine: .webkit, in: right.handle, activate: true)
            try await PinnedPageTests.until({ store.tab(surface: a.surface) != nil })
            let aID = try #require(store.tab(surface: a.surface)).id
            let controller = try #require(services.paneController(for: right))
            try await PinnedPageTests.until({ controller.orderedIDs.count == 2 && controller.orderedIDs.map(\.rawValue).contains(aID) },
                                            report: { "\(controller.orderedIDs)" })
            let bID = try #require(controller.orderedIDs.first { $0.rawValue != aID })
            let layout = try #require(controller.workspace?.layoutModel)
            let paneID = controller.layoutPaneID
            let undo = try #require(services.closedTabs?.undoToasts)
            undo.pageDecidesClose = { _, tab in tab.rawValue == aID }

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: aID), origin: .user)))
            try #require(undo.hiddenPages.contains(aID) && !layout.isClosing(paneID))
            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: bID.rawValue), origin: .user).confirmed()))
            try await PinnedPageTests.until({ layout.isClosing(paneID) }, within: .seconds(5), report: { "B's close never took the pane out" })
            #expect(undo.hiddenPages.restore(aID))
            #expect(!layout.isClosing(paneID), "the pane stayed closed while A asks")
            try await PinnedPageTests.until({ services.paneController(for: right)?.stripModel.selectedID?.rawValue == aID }, within: .seconds(5),
                                            report: { "A is not back, selected: \(services.paneController(for: right)?.orderedIDs ?? [])" })
        }
    }

    /// The page's question comes right at the deadline, before its watch wakes: the deadline brings the tab back for the
    /// question, never closes it (that would answer Leave for the person). Review of #32876 at 9b8ed262253.
    @Test func aQuestionAtTheDeadlineBringsTheTabBackNeverClosesIt() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(services.windows.active?.focusedPane)
            let handle = pane.pane.handle
            let kept = try await connection.newFrontendBrowserTab(url: "https://example.com/kept", engine: .webkit, in: handle, activate: false)
            let asking = try await connection.newFrontendBrowserTab(url: "https://example.com/form", engine: .webkit, in: handle, activate: false)
            try await PinnedPageTests.until({ [kept, asking].allSatisfy { store.tab(surface: $0.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true } })
            let tab = try #require(store.tab(surface: asking.surface))
            let undo = try #require(services.closedTabs?.undoToasts)
            nonisolated(unsafe) var asks = false
            undo.hiddenPages.hide([(id: tab.id, surface: tab.surface, asks: { asks })], in: pane, store: store)
            try #require(!pane.orderedIDs.map(\.rawValue).contains(tab.id))
            asks = true
            undo.hiddenPages.expire(tab.id) // in the same turn: the watch has not woken
            #expect(!undo.hiddenPages.contains(tab.id))
            #expect(pane.orderedIDs.map(\.rawValue).contains(tab.id), "the deadline did not bring the asking tab back")
            try await Task.sleep(for: .milliseconds(500))
            #expect(store.liveTreeLists(tab: tab.id) == true, "the deadline closed a page that asks")
        }
    }

    /// The measure (same harness at base and head): a person's close of a deciding page's tab to the
    /// tab gone from its strip, 20 rounds. The page never answers within the round's 1 s, as a slow
    /// renderer; then it closes the tab (the `closeTab` its page's close runs). Prints p50/p95.
    @Test func measureCloseToStripDrop() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(services.windows.active?.focusedPane)
            let handle = pane.pane.handle
            let undo = try #require(services.closedTabs?.undoToasts)
            var deciding: Set<String> = []
            undo.pageDecidesClose = { _, tab in deciding.contains(tab.rawValue) }
            var samples: [Double] = []
            var stayed = 0
            for round in 0..<20 {
                let page = try await connection.newFrontendBrowserTab(url: "https://example.com/m\(round)", engine: .webkit, in: handle, activate: false)
                try await PinnedPageTests.until({ store.tab(surface: page.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true })
                let id = try #require(store.tab(surface: page.surface)).id
                deciding = [id]
                let start = ContinuousClock.now
                _ = services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user))
                let deadline = start + .seconds(1)
                while pane.orderedIDs.map(\.rawValue).contains(id), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
                if pane.orderedIDs.map(\.rawValue).contains(id) { stayed += 1 } else {
                    let elapsed = start.duration(to: .now)
                    samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                }
                deciding = []
                _ = services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id)))
                try await PinnedPageTests.until({ store.liveTreeLists(tab: id) == false }, within: .seconds(10))
            }
            let sorted = samples.sorted()
            func pct(_ p: Double) -> String { sorted.isEmpty ? "-" : String(format: "%.2f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]) }
            print("MEASURE close->strip-drop rounds=20 dropped=\(sorted.count) stayed-past-1s=\(stayed) p50_ms=\(pct(0.5)) p95_ms=\(pct(0.95))")
        }
    }

    /// A page that neither closes nor asks by the deadline (a hung renderer) closes without asking: its
    /// tab never comes back unasked, since the close took effect on the click.
    @Test func aPageThatNeverDecidesClosesItsTabAtTheDeadlineAndNeverBringsItBack() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(services.windows.active?.focusedPane)
            let handle = pane.pane.handle
            let kept = try await connection.newFrontendBrowserTab(url: "https://example.com/kept", engine: .webkit, in: handle, activate: false)
            let hung = try await connection.newFrontendBrowserTab(url: "https://example.com/hung", engine: .webkit, in: handle, activate: false)
            try await PinnedPageTests.until({ [kept, hung].allSatisfy { store.tab(surface: $0.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true } })
            let id = try #require(store.tab(surface: hung.surface)).id
            let undo = try #require(services.closedTabs?.undoToasts)
            undo.hiddenPages.deadline = .milliseconds(300)
            defer { undo.hiddenPages.deadline = .seconds(5) }
            undo.pageDecidesClose = { _, tab in tab.rawValue == id }

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user)))
            var cameBack = false
            let deadline = ContinuousClock.now + .seconds(10)
            while store.liveTreeLists(tab: id) != false, ContinuousClock.now < deadline {
                if pane.orderedIDs.map(\.rawValue).contains(id) { cameBack = true }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!cameBack, "the hung page's tab came back with no question")
            #expect(store.liveTreeLists(tab: id) == false, "the hung page's tab was never closed: \(store.pane(handle)?.tabs.map(\.id) ?? [])")
            #expect(store.tab(surface: kept.surface) != nil, "the other tab closed")
        }
    }

    /// A page that asks ("Leave site?") brings its tab back at its place, selected, before the
    /// question (`HiddenPageCloses.restore`, which the page's question and its `.activate` run).
    @Test func aPageThatAsksBringsItsTabBackSelected() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(services.windows.active?.focusedPane)
            let handle = pane.pane.handle
            let kept = try await connection.newFrontendBrowserTab(url: "https://example.com/kept", engine: .webkit, in: handle, activate: false)
            let asking = try await connection.newFrontendBrowserTab(url: "https://example.com/form", engine: .webkit, in: handle, activate: false)
            try await PinnedPageTests.until({ [kept, asking].allSatisfy { store.tab(surface: $0.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true } })
            let id = try #require(store.tab(surface: asking.surface)).id
            let order = pane.orderedIDs
            let undo = try #require(services.closedTabs?.undoToasts)
            undo.pageDecidesClose = { _, tab in tab.rawValue == id }

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user)))
            try #require(!pane.orderedIDs.map(\.rawValue).contains(id))
            #expect(undo.hiddenPages.restore(id))
            #expect(pane.orderedIDs == order, "the tab came back out of place: \(pane.orderedIDs) for \(order)")
            try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == id },
                                            report: { "the asking tab is not selected: \(pane.stripModel.selectedID?.rawValue ?? "-")" })
            #expect(!undo.hiddenPages.contains(id))
            #expect(store.tab(surface: asking.surface) != nil)
        }
    }

    /// A pane whose last tab is a deciding page leaves its window in the click's turn (the right
    /// pane Leo closed); the page's close then closes the pane for real.
    @Test func aPaneWhoseLastTabIsADecidingPageLeavesInTheClicksTurn() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let window = try #require(services.windows.active)
            let first = try #require(window.workspaceContent?.panes.values.first?.pane)
            _ = try await connection.split(first.handle, direction: .right)
            let screenPanes = { store.workspaces.flatMap(\.screens).first { $0.panes.contains { $0 === first } }?.panes ?? [] }
            try await PinnedPageTests.until({ screenPanes().count == 2 && screenPanes().allSatisfy { !$0.tabs.isEmpty } && window.workspaceContent?.panes.count == 2 },
                                            within: .seconds(30), report: { "\(screenPanes().count) panes" })
            let right = try #require(screenPanes().first { $0 !== first })
            let rightHandle = right.handle
            let page = try await connection.newFrontendBrowserTab(url: "https://example.com/right", engine: .webkit, in: rightHandle, activate: true)
            try await PinnedPageTests.until({ store.tab(surface: page.surface) != nil })
            let id = try #require(store.tab(surface: page.surface)).id
            // The right pane keeps only the page: its terminal closes as a script closes it (no question).
            for tab in right.tabs where tab.id != id {
                #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .cli)))
            }
            let controller = try #require(services.paneController(for: right))
            try await PinnedPageTests.until({ controller.orderedIDs.map(\.rawValue) == [id] }, report: { "\(controller.orderedIDs)" })
            let layout = try #require(controller.workspace?.layoutModel)
            let undo = try #require(services.closedTabs?.undoToasts)
            var deciding: Set<String> = [id]
            undo.pageDecidesClose = { _, tab in deciding.contains(tab.rawValue) }

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user)))
            #expect(layout.isClosing(controller.layoutPaneID), "the pane waits on screen for its page to decide")
            #expect(controller.orderedIDs.isEmpty, "the closed tab waits in its strip: \(controller.orderedIDs)")

            deciding.remove(id)
            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id))))
            try await PinnedPageTests.until({ screenPanes().count == 1 }, within: .seconds(10),
                                            report: { "the page's close left \(screenPanes().count) panes" })
            #expect(store.liveTreeLists(tab: id) == false)
        }
    }

    /// The emptied pane's close lands (the layout lets go of its controller, at once under Reduce Motion), then the
    /// page asks: the pane and its tab come back, selected. Review of #32876 at b24bc3a92fe: the hide held its pane
    /// weakly, so the question was skipped and the pane stayed closed with the page asking behind it.
    @Test func aPageThatAsksAfterItsPanesCloseLandedBringsThePaneBack() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let window = try #require(services.windows.active)
            let first = try #require(window.workspaceContent?.panes.values.first?.pane)
            _ = try await connection.split(first.handle, direction: .right)
            let screenPanes = { store.workspaces.flatMap(\.screens).first { $0.panes.contains { $0 === first } }?.panes ?? [] }
            try await PinnedPageTests.until({ screenPanes().count == 2 && screenPanes().allSatisfy { !$0.tabs.isEmpty } && window.workspaceContent?.panes.count == 2 },
                                            within: .seconds(30), report: { "\(screenPanes().count) panes" })
            let right = try #require(screenPanes().first { $0 !== first })
            let page = try await connection.newFrontendBrowserTab(url: "https://example.com/asks", engine: .webkit, in: right.handle, activate: true)
            try await PinnedPageTests.until({ store.tab(surface: page.surface) != nil })
            let id = try #require(store.tab(surface: page.surface)).id
            for tab in right.tabs where tab.id != id {
                #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .cli)))
            }
            let controller = try #require(services.paneController(for: right))
            try await PinnedPageTests.until({ controller.orderedIDs.map(\.rawValue) == [id] }, report: { "\(controller.orderedIDs)" })
            let layout = try #require(controller.workspace?.layoutModel)
            let paneID = controller.layoutPaneID
            let undo = try #require(services.closedTabs?.undoToasts)
            undo.pageDecidesClose = { _, tab in tab.rawValue == id }

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user)))
            try #require(layout.isClosing(paneID))
            // The close lands and the layout lets go of the pane's controller; nothing else holds it.
            try await PinnedPageTests.until({ window.workspaceContent?.panes.count == 1 }, within: .seconds(5),
                                            report: { "\(window.workspaceContent?.panes.count ?? 0) pane controllers" })
            #expect(undo.hiddenPages.restore(id))
            #expect(!layout.isClosing(paneID), "the pane stayed closed while its page asks")
            try await PinnedPageTests.until({ services.paneController(for: right)?.stripModel.selectedID?.rawValue == id }, within: .seconds(5),
                                            report: { "the asking tab is not back, selected: \(services.paneController(for: right)?.orderedIDs ?? [])" })
        }
    }
}
