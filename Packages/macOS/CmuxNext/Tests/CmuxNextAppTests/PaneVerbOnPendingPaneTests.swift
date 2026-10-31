import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSettings
import Foundation
import Testing

/// P0 2026-10-30, lead decision on rule (b): a pane verb that is not a create (Toggle Pane Zoom, Rename Pane, Swap) on a
/// pending split's stand-in is never sent to the daemon; it fails at once with a notice in the refusal HUD ("This pane is
/// still opening ..."), and the layout stays as it was. Before, the stand-in's handle went to the daemon ("unknown pane",
/// shown nowhere). A create (a split, a new tab) on that stand-in is not refused: it waits for the daemon's pane
/// (`DaemonStore.daemonTarget`, P0 STATUS 2080).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct PaneVerbOnPendingPaneTests {
    @Test func zoomOnAPendingSplitsPaneShowsANoticeAndChangesNothing() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            let before = Set(content.panes.keys)
            // One main-actor turn, no await: the split's reply cannot have come; its stand-in has the focus.
            #expect(services.registry.perform("splitDown", invocation: terminal))
            let pending = try #require(content.panes.first { !before.contains($0.key) }?.value, "the split shows no pane in its turn")
            #expect(pending.pane.handle.rawValue >= ProvisionalPane.firstHandle, "the split already confirmed")
            PaneHandlers.focus(pending.layoutPaneID, in: content)
            let shown = services.refusalHUD.shownCount
            #expect(services.registry.perform("toggleSplitZoom", invocation: ActionInvocation(origin: .user)))

            try await PinnedPageTests.until({ services.refusalHUD.shownCount > shown }, report: {
                "zoom on the pending pane showed nothing (HUD \(services.refusalHUD.shownCount), was \(shown))"
            })
            let notice = services.refusalHUD.message ?? ""
            #expect(notice.contains(RefusalStrings.paneStillOpening), "the notice is not the pane-still-opening one: \(notice)")
            #expect(!notice.localizedCaseInsensitiveContains("unknown pane"), "the stand-in reached the daemon: \(notice)")
            // The split confirms; nothing was zoomed.
            try await PinnedPageTests.until({ content.panes.values.allSatisfy { $0.pane.handle.rawValue < ProvisionalPane.firstHandle } },
                                            report: { "the split did not confirm" })
            #expect(services.daemon.store.workspaces.allSatisfy { $0.screens.allSatisfy { $0.zoomedPane == nil } },
                    "a pane was zoomed after a refused zoom")
            #expect(services.refusalHUD.shownCount == shown + 1, "the refusal showed \(services.refusalHUD.shownCount - shown) times")
        }
    }

    /// Split Left on a pane still opening is a non-optimistic split (it swaps after). The stand-in is never sent (rule b),
    /// and the split is not refused either (P0 STATUS 2080, a create belongs to the pane it was pressed on): it waits for
    /// the pending split's daemon pane (`DaemonStore.daemonTarget`) and splits that one, with no notice.
    @Test func splitLeftOnAPendingSplitsPaneSplitsItsDaemonPaneWithNoNotice() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            let before = Set(content.panes.keys)
            #expect(services.registry.perform("splitDown", invocation: terminal))
            let pending = try #require(content.panes.first { !before.contains($0.key) }?.value, "the split shows no pane in its turn")
            #expect(pending.pane.handle.rawValue >= ProvisionalPane.firstHandle, "the split already confirmed")
            PaneHandlers.focus(pending.layoutPaneID, in: content)
            let shown = services.refusalHUD.shownCount
            var failures: [String] = []
            let work = services.registry.capturingWork { _ = services.registry.perform("splitLeft", invocation: terminal) }
            for task in work { if let failure = await task.value { failures.append(failure.message) } }

            // The first split confirms, and Split Left made a third pane beside its daemon pane, with no notice.
            try await PinnedPageTests.until({
                content.panes.count == before.count + 2 && content.panes.values.allSatisfy { $0.pane.handle.rawValue < ProvisionalPane.firstHandle }
            }, report: { "Split Left on the pending pane made no pane: \(content.panes.count) panes, failures \(failures)" })
            #expect(failures.isEmpty, "Split Left on the pending pane failed: \(failures)")
            #expect(services.refusalHUD.shownCount == shown, "a refusal showed: \(services.refusalHUD.message ?? "")")
        }
    }

    /// Review #6 B2: a refusal is never silent, on any funnel. A command naming a pane still opening, run outside any
    /// capturing run through `DaemonService.request` (which only logs its error) or `perform` (whose caller drops it),
    /// shows the pane-still-opening notice once each.
    @Test func everyFunnelShowsAPaneNotReadyRefusalOnce() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let standIn = ProvisionalPane().handle
            let shown = services.refusalHUD.shownCount
            _ = await services.daemon.request("zoom-pane") { connection in _ = try await connection.zoomPane(standIn) }
            try await PinnedPageTests.until({ services.refusalHUD.shownCount > shown }, report: {
                "request on a pane still opening showed nothing (HUD \(services.refusalHUD.shownCount), was \(shown))"
            })
            _ = try? await services.daemon.perform("zoom-pane") { connection in _ = try await connection.zoomPane(standIn) }
            try await PinnedPageTests.until({ services.refusalHUD.shownCount > shown + 1 }, report: {
                "perform on a pane still opening showed nothing (HUD \(services.refusalHUD.shownCount), was \(shown + 1))"
            })
            #expect(services.refusalHUD.shownCount == shown + 2, "two refusals showed \(services.refusalHUD.shownCount - shown) notices")
            #expect(services.refusalHUD.message?.contains(RefusalStrings.paneStillOpening) == true,
                    "the notice is not the pane-still-opening one: \(services.refusalHUD.message ?? "")")
        }
    }

    /// A cmux.json `newTabInCurrentPane` command (`ConfigCommandRunner`, the typed New Tab page path) on a pending split's
    /// pane: the stand-in is never sent (rule b), and the tab is not refused either (P0 STATUS 2080): it waits for the
    /// split's daemon pane and opens there, with no notice.
    @Test func aCommandTypedIntoANewTabOnAPendingPaneOpensInItsDaemonPane() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            let before = Set(content.panes.keys)
            let tabsBefore = content.panes.values.reduce(0) { $0 + $1.pane.tabs.count }
            #expect(services.registry.perform("splitDown", invocation: terminal))
            let pending = try #require(content.panes.first { !before.contains($0.key) }?.value, "the split shows no pane in its turn")
            #expect(pending.pane.handle.rawValue >= ProvisionalPane.firstHandle, "the split already confirmed")
            let shown = services.refusalHUD.shownCount
            // `ConfigCommandRunner.run` for `newTabInCurrentPane`: the targeted pane's controller types into a new tab.
            pending.newTerminalTab(typing: "true\r")

            // The split confirms, and the typed tab opens in its daemon pane: the split's tab plus this one.
            try await PinnedPageTests.until({
                content.panes.values.allSatisfy { $0.pane.handle.rawValue < ProvisionalPane.firstHandle }
                    && content.panes.values.reduce(0) { $0 + $1.pane.tabs.count } == tabsBefore + 2
            }, report: {
                "the typed new tab did not open: \(content.panes.values.reduce(0) { $0 + $1.pane.tabs.count }) tabs, \(tabsBefore) before the split; HUD \(services.refusalHUD.message ?? "none")"
            })
            #expect(services.refusalHUD.shownCount == shown, "a refusal showed: \(services.refusalHUD.message ?? "")")
        }
    }

    /// Perf review B1 at b898fc6c2d3: a person's run (a key, the menu, the palette) binds a person command scope that
    /// never closes. A cmux.json `newTabInCurrentPane` command run through the registry with origin `.user` on a pending
    /// split's pane is a create: since P0 STATUS 2080 (#29530) it waits for the split's daemon pane and opens its tab
    /// there, with no notice (it showed a pane-still-opening refusal before).
    @Test func aPersonsConfigCommandOnAPendingPaneOpensInItsDaemonPane() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let command = ConfigCommandAction(name: "p0PendingTyped", title: "P0 pending typed", command: "true")
            services.configActions.apply([command])
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            let before = Set(content.panes.keys)
            let tabsBefore = content.panes.values.reduce(0) { $0 + $1.pane.tabs.count }
            #expect(services.registry.perform("splitDown", invocation: terminal))
            let pending = try #require(content.panes.first { !before.contains($0.key) }?.value, "the split shows no pane in its turn")
            #expect(pending.pane.handle.rawValue >= ProvisionalPane.firstHandle, "the split already confirmed")
            PaneHandlers.focus(pending.layoutPaneID, in: content)
            let shown = services.refusalHUD.shownCount
            // The palette's or a shortcut's run: the registry, origin `.user` (a person scope is bound for it).
            #expect(services.registry.perform(ActionID(rawValue: command.actionID), invocation: ActionInvocation(origin: .user)))

            // The split confirms, and the typed command's tab opens in its daemon pane: the split's tab plus this one.
            try await PinnedPageTests.until({
                content.panes.values.allSatisfy { $0.pane.handle.rawValue < ProvisionalPane.firstHandle }
                    && content.panes.values.reduce(0) { $0 + $1.pane.tabs.count } == tabsBefore + 2
            }, report: {
                "a person's typed command on the pending pane opened no tab: \(content.panes.values.reduce(0) { $0 + $1.pane.tabs.count }) tabs, \(tabsBefore) before the split; HUD \(services.refusalHUD.message ?? "none")"
            })
            #expect(services.refusalHUD.shownCount == shown, "a refusal showed: \(services.refusalHUD.message ?? "")")
        }
    }
}
