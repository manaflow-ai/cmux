import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
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
}
