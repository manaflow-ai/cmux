import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Measure only, never merges (decision 2026-11-16): the spans of one New Tab key and of one store event on a whole
/// window of the `real` session (826 workspaces, 1,600 tabs), as a report.
///
/// The prints are the report. The one condition is of the setup (the key added one tab). Limits: a debug build, no
/// daemon (no creation is answered), and each page has an inert address (it loads nothing), so the rows give counts
/// and shares of the app's part of a key, not the product's times. The spans are nested (`newTab.places` is in
/// `newTab.omnibar`; `store.lift.*` is in `store.apply.*`): a sum of the rows counts a part more than one time.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct NewTabKeySpansReportTests {
    /// The creations of one test: each waits here, so the daemon's side answers none before `release()`.
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

    /// The spans by name, in the order of their first start: how many, the sum and the longest one, in ms.
    private static func rows(_ spans: [BenchSpans.Span]) -> String {
        var order: [String] = []
        var byName: [String: (count: Int, sum: Double, most: Double)] = [:]
        for span in spans {
            if byName[span.name] == nil { order.append(span.name) }
            let old = byName[span.name] ?? (0, 0, 0)
            byName[span.name] = (old.count + 1, old.sum + span.milliseconds, max(old.most, span.milliseconds))
        }
        return order.map { name in
            let row = byName[name] ?? (0, 0, 0)
            return "\(name) n=\(row.count) sum=\(String(format: "%.2f", row.sum)) max=\(String(format: "%.2f", row.most))"
        }.joined(separator: "; ")
    }

    @Test func threeNewTabKeysAndOneStoreEventPrintTheirSpans() async throws {
        // An inert address for each New Tab page: the pages load nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        try await LargeSessionWindowFixture.withController(.real, agentPaneEnvironment: environment) { store, controller in
            let services = controller.services
            let tabs = services.agentTabs
            try #require(tabs.canHostChat, "setup: this build has no New Tab page")
            let pane = try #require(controller.focusedPane, "setup: the window has no focused pane")
            let held = HeldCreations()
            tabs.localHost = AgentSessionRef.host(installID: "new-tab-key-spans-report")
            tabs.holdsTabs = { _ in true }
            tabs.reachable = { _ in true }
            tabs.create = { _, _, _, _, _, _ in
                await held.wait()
                throw CancellationError()
            }
            store.onApplyTimed = { name, began in BenchSpans.mark(name, milliseconds: BenchSpans.ms(.now - began)) }
            let workspaces = store.workspaces.count
            var made = 0
            for key in 1...3 {
                let before = pane.orderedIDs.count
                _ = SidebarPerfCounters.report(reset: true)
                BenchSpans.begin()
                let began = ContinuousClock.now
                let ran = services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user))
                let call = BenchSpans.ms(.now - began)
                let inCall = BenchSpans.spans
                await LargeSessionWindowFixture.drainMain()
                let all = BenchSpans.end()
                let sidebar = SidebarPerfCounters.report(reset: true)
                made += pane.orderedIDs.count - before
                print("new tab key spans, \(workspaces) workspaces, key \(key) (\(ran ? "ran" : "refused")): the call took "
                    + "\(String(format: "%.2f", call)) ms; in the call: \(Self.rows(inCall))")
                print("new tab key spans, \(workspaces) workspaces, key \(key): after the call (what the main actor had queued): "
                    + "\(Self.rows(Array(all.dropFirst(inCall.count)))); sidebar rebuilds \(sidebar["rebuilds"] ?? 0), "
                    + "list_reloads \(sidebar["list_reloads"] ?? 0), row_views_made \(sidebar["row_views_made"] ?? 0), "
                    + "row_maps \(sidebar["row_maps"] ?? 0)")
            }

            // One event of the daemon for a terminal of a hidden workspace: the store's apply and what it wakes.
            _ = SidebarPerfCounters.report(reset: true)
            BenchSpans.begin()
            let began = ContinuousClock.now
            let surface = LargeSessionWindowFixture.agents(.real)[0]
            store.apply(LargeSessionWindowFixture.titleChanged(surface, raw: "report", text: "report", activity: nil))
            let call = BenchSpans.ms(.now - began)
            await LargeSessionWindowFixture.drainMain()
            let spans = BenchSpans.end()
            let sidebar = SidebarPerfCounters.report(reset: true)
            print("new tab key spans, \(workspaces) workspaces, one title event: the apply took \(String(format: "%.2f", call)) ms; "
                + "spans: \(Self.rows(spans)); sidebar rebuilds \(sidebar["rebuilds"] ?? 0), list_reloads \(sidebar["list_reloads"] ?? 0), "
                + "row_patches \(sidebar["row_patches"] ?? 0), row_maps \(sidebar["row_maps"] ?? 0)")

            store.onApplyTimed = nil
            // Each creation ends before the window closes.
            held.release()
            await LargeSessionWindowFixture.drainMain()
            #expect(made >= 1, "setup: 3 New Tab keys added no tab to the strip")
        }
    }
}
