import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// User 2026-10-20: "I did a bunch of Command-Ts and then for some reason they closed themselves.
/// I expanded it and then they closed themselves." Nothing closed: the daemon kept all 18 New Tab
/// pages and selected the newest, but the app's strip selected the tab the presses started from
/// again and scrolled the new tabs out of view. Many Cmd-T presses at key-repeat speed, then what
/// the person did next (the pane zoomed and back, the window resized): every new tab stays in the strip, the selection stays on the newest one, it
/// never goes back to the tab the presses started from, and the newest tab is in view.
/// Not covered yet: a sidebar group collapsed and expanded after the presses (the user's "I
/// expanded it"). This harness's sidebar lists no daemon or personal groups, so that step cannot run here.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdTSpamKeepsNewTabsTests {
    private static let presses = 18

    enum After: String, CaseIterable, Sendable { case nothing, paneZoom, windowResize }

    @Test(arguments: After.allCases)
    func cmdTSpamThenKeepsTheNewestTabSelectedAndShown(after: After) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdt-spam")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let window = try #require(services.windows.active)
            let pane = try #require(window.focusedPane)
            let store = services.daemon.store
            // The window is narrow enough that 18 more tabs overflow its strip (the Home right pane).
            window.window?.setFrame(NSRect(x: 100, y: 100, width: 900, height: 600), display: true)
            // The tab the presses start from: a page, as the Home right pane's selected tab was.
            let opener = try await connection.newFrontendBrowserTab(url: "https://example.com/opener", engine: .webkit,
                                                                     in: pane.pane.handle, activate: false)
            try await PasswordManagerRouteTests.until { store.tab(surface: opener.surface) != nil }
            let openerID = try #require(store.tab(surface: opener.surface)).id
            try await PasswordManagerRouteTests.until { pane.orderedIDs.contains { $0.rawValue == openerID } }
            pane.select(TabID(openerID))
            try #require(pane.stripModel.selectedID?.rawValue == openerID)
            let before = Set(store.pane(pane.pane.handle)?.tabs.map(\.id) ?? [])

            // Each step's selection, for the failure message: o = opener, p = provisional, d = daemon tab.
            var trace: [String] = []
            var backToOpener: [String] = []
            @MainActor func mark(_ step: String) {
                let id = pane.stripModel.selectedID?.rawValue ?? "-"
                let kind = id == openerID ? "o" : ProvisionalTab.isProvisional(id) ? "p" : "d"
                if trace.last?.hasSuffix(":" + kind) != true { trace.append("\(step):\(kind)") }
                if id == openerID { backToOpener.append(step) }
            }
            for press in 0..<Self.presses {
                #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
                // Key repeat: the next press comes before the daemon answers this one.
                try await Task.sleep(for: .milliseconds(30))
                mark("\(press + 1)")
            }
            @MainActor func made() -> [TabModel] {
                (store.pane(pane.pane.handle)?.tabs ?? []).filter { !before.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }
            }
            try await PasswordManagerRouteTests.until({ made().count == Self.presses }, report: { "daemon tabs made: \(made().count)" })
            try await PasswordManagerRouteTests.until({ !pane.orderedIDs.contains { ProvisionalTab.isProvisional($0.rawValue) } },
                                                      report: { "strip: \(pane.orderedIDs.map(\.rawValue))" })
            mark("made")

            switch after {
            case .nothing:
                break
            case .paneZoom:
                #expect(services.registry.perform("toggleSplitZoom", invocation: ActionInvocation(origin: .user)))
                try await Task.sleep(for: .milliseconds(500))
                mark("zoomed")
                #expect(services.registry.perform("toggleSplitZoom", invocation: ActionInvocation(origin: .user)))
            case .windowResize:
                window.window?.setFrame(NSRect(x: 100, y: 100, width: 1400, height: 700), display: true)
                try await Task.sleep(for: .milliseconds(300))
                mark("wide")
                window.window?.setFrame(NSRect(x: 100, y: 100, width: 700, height: 600), display: true)
            }
            // Settled: past the new-tab placement window and any restore of the pane.
            let settle = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < settle {
                mark("settle")
                try await Task.sleep(for: .milliseconds(20))
            }

            let livePane = try #require(services.windows.active?.workspaceContent?.panes.values.first { $0.pane.handle == pane.pane.handle },
                                        "the pane left the window")
            let newest = try #require(made().max { $0.surface.rawValue < $1.surface.rawValue })
            let shown = Set(livePane.orderedIDs.map(\.rawValue))
            #expect(made().allSatisfy { shown.contains($0.id) }, "a new tab left the strip: \(made().map(\.id).filter { !shown.contains($0) })")
            #expect(backToOpener.isEmpty, "the selection went back to the tab the presses started from at \(backToOpener); trace \(trace)")
            #expect(livePane.stripModel.selectedID?.rawValue == newest.id,
                    "selected \(livePane.stripModel.selectedID?.rawValue ?? "none"), newest \(newest.id), opener \(openerID); trace \(trace)")
            // The newest tab is in the strip's view, not scrolled past an edge.
            livePane.view.stripView.layoutSubtreeIfNeeded()
            let strip = livePane.view.stripView
            let slot = try #require(strip.result.slot(TabID(newest.id)), "no slot for the newest tab")
            let left = slot.x - strip.scrollOffset, right = left + slot.width
            #expect(left >= -1 && right <= strip.viewportWidth + 1,
                    "the newest tab is out of view: x \(left)...\(right), viewport \(strip.viewportWidth), content \(strip.result.contentWidth)")
        }
    }
}
