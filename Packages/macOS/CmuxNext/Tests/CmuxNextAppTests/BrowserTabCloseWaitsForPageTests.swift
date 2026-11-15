import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// User 2026-11-12: "i press cmd w, it closes the tab, then it shows the leave site dialog (and reopens the
/// page itself)". As in Chrome, a person's close of a live Chromium tab whose page runs beforeunload
/// (`BrowserUserClosing`) keeps the tab where it is, selected, while the page decides: the page's own close
/// (no handler, or Leave) closes it then; a page that asks keeps it as it was on Stay, the same page, never
/// taken out and brought back. The page that decides is the injected `pageDecidesClose`; its own close is
/// the `.close` request BrowserPageRequests gets (as `CEFTab.browserDidClose` sends it). Through the app
/// against a same-tree daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct BrowserTabCloseWaitsForPageTests {
    /// Cmd-W on a deciding page's tab: it stays in its strip, at its place and selected, until its page closes it.
    @Test func aDecidingPagesTabStaysInPlaceUntilItsPageCloses() async throws {
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
            let order = pane.orderedIDs
            let undo = try #require(services.closedTabs?.undoToasts)
            var deciding: Set<String> = [id]
            undo.pageDecidesClose = { _, tab in deciding.contains(tab.rawValue) }

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user)))
            #expect(pane.orderedIDs == order, "the tab left its strip before its page decided: \(pane.orderedIDs) for \(order)")
            #expect(pane.stripModel.selectedID?.rawValue == id, "the deciding tab lost the selection")

            // The page closes (no handler, or Leave): its tab closes then, at once.
            deciding.remove(id)
            services.cache.pageRequests.browserTab(page, didRequest: .close)
            try await PinnedPageTests.until({ store.liveTreeLists(tab: id) == false }, within: .seconds(4),
                                            report: { "the page's close did not close its tab: \(store.pane(handle)?.tabs.map(\.id) ?? [])" })
            #expect(!pane.orderedIDs.map(\.rawValue).contains(id))
            #expect(store.tab(surface: kept.surface) != nil, "the other tab closed")
        }
    }

    /// The page asks ("Leave site?") and the person stays: the tab never left its strip, stays selected with the
    /// same page (no new page, no reload), and nothing closes it later without asking.
    @Test func aPageThatAsksKeepsItsTabAndPageWhenThePersonStays() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(services.windows.active?.focusedPane)
            let handle = pane.pane.handle
            let kept = try await connection.newFrontendBrowserTab(url: "https://example.com/kept", engine: .webkit, in: handle, activate: false)
            let asking = try await connection.newFrontendBrowserTab(url: "https://example.com/form", engine: .webkit, in: handle, activate: true)
            try await PinnedPageTests.until({ [kept, asking].allSatisfy { store.tab(surface: $0.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true } })
            let id = try #require(store.tab(surface: asking.surface)).id
            pane.select(StripTabID(id))
            try await PinnedPageTests.until({ services.cache.browsers[id] != nil }, report: { "the page of \(id) was never made" })
            let page = try #require(services.cache.browsers[id]?.tab)
            let order = pane.orderedIDs
            let undo = try #require(services.closedTabs?.undoToasts)
            undo.pageDecidesClose = { _, tab in tab.rawValue == id }

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user)))
            // The page asks and the person answers Stay: the page never closes. Watch past any close deadline.
            var left = false
            let until = ContinuousClock.now + .seconds(6)
            while ContinuousClock.now < until {
                if pane.orderedIDs != order || pane.stripModel.selectedID?.rawValue != id { left = true }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!left, "the asking tab left its strip or its selection")
            #expect(pane.orderedIDs == order)
            #expect(services.cache.browsers[id]?.tab === page, "the tab got a new page (reloaded)")
            #expect(store.liveTreeLists(tab: id) == true, "a page that asks was closed without the person's Leave")
        }
    }

    /// A pane whose last tab is a deciding page stays on screen with it; the page's close then closes the pane.
    @Test func aPaneWhoseLastTabIsADecidingPageStaysUntilThePageCloses() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let window = try #require(services.windows.active)
            let first = try #require(window.workspaceContent?.panes.values.first?.pane)
            _ = try await connection.split(first.handle, direction: .right)
            let screenPanes = { store.workspaces.flatMap(\.screens).first { $0.panes.contains { $0 === first } }?.panes ?? [] }
            try await PinnedPageTests.until({ screenPanes().count == 2 && screenPanes().allSatisfy { !$0.tabs.isEmpty } && window.workspaceContent?.panes.count == 2 },
                                            within: .seconds(30), report: { "\(screenPanes().count) panes" })
            let right = try #require(screenPanes().first { $0 !== first })
            let created = try await connection.newFrontendBrowserTab(url: "https://example.com/right", engine: .webkit, in: right.handle, activate: true)
            try await PinnedPageTests.until({ store.tab(surface: created.surface) != nil })
            let id = try #require(store.tab(surface: created.surface)).id
            // The right pane keeps only the page: its terminal closes as a script closes it (no question).
            for tab in right.tabs where tab.id != id {
                #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .cli)))
            }
            let controller = try #require(services.paneController(for: right))
            try await PinnedPageTests.until({ controller.orderedIDs.map(\.rawValue) == [id] }, report: { "\(controller.orderedIDs)" })
            try await PinnedPageTests.until({ services.cache.browsers[id] != nil }, report: { "the page of \(id) was never made" })
            let page = try #require(services.cache.browsers[id]?.tab)
            let layout = try #require(controller.workspace?.layoutModel)
            let undo = try #require(services.closedTabs?.undoToasts)
            var deciding: Set<String> = [id]
            undo.pageDecidesClose = { _, tab in deciding.contains(tab.rawValue) }

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .user)))
            #expect(!layout.isClosing(controller.layoutPaneID), "the pane left before its page decided")
            #expect(controller.orderedIDs.map(\.rawValue) == [id], "the deciding tab left its strip: \(controller.orderedIDs)")

            deciding.remove(id)
            services.cache.pageRequests.browserTab(page, didRequest: .close)
            try await PinnedPageTests.until({ screenPanes().count == 1 }, within: .seconds(10),
                                            report: { "the page's close left \(screenPanes().count) panes" })
            #expect(store.liveTreeLists(tab: id) == false)
        }
    }

    /// Both tabs of a split pane are deciding pages, closed in one gesture: they stay until their pages close (their
    /// `.close` requests), and the gesture is still ONE Reopen Closed step (Lawrence 2026-10-23).
    @Test func closingAPanesDecidingPagesIsOneReopenStep() async throws {
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
            #expect(!layout.isClosing(paneID), "the pane left before its pages decided")
            #expect(Set(controller.orderedIDs.map(\.rawValue)) == Set(ids), "deciding tabs left their strip: \(controller.orderedIDs)")
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
}
