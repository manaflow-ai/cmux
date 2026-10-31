import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// P0 2026-10-30, lead decision on rule (b): a pane verb that is not a create (Toggle Pane Zoom, Rename Pane, Swap) on a
/// pending split's stand-in is never sent to the daemon; it fails at once with a notice in the refusal HUD ("This pane is
/// still opening ..."), and the layout stays as it was. Before, the stand-in's handle went to the daemon ("unknown pane",
/// shown nowhere).
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
            #expect(notice.contains(MiscHandlerStrings.paneNotReady), "the notice is not the pane-still-opening one: \(notice)")
            #expect(!notice.localizedCaseInsensitiveContains("unknown pane"), "the stand-in reached the daemon: \(notice)")
            // The split confirms; nothing was zoomed.
            try await PinnedPageTests.until({ content.panes.values.allSatisfy { $0.pane.handle.rawValue < ProvisionalPane.firstHandle } },
                                            report: { "the split did not confirm" })
            #expect(services.daemon.store.workspaces.allSatisfy { $0.screens.allSatisfy { $0.zoomedPane == nil } },
                    "a pane was zoomed after a refused zoom")
            #expect(services.refusalHUD.shownCount == shown + 1, "the refusal showed \(services.refusalHUD.shownCount - shown) times")
        }
    }

    /// Review #6: Split Left on a pane still opening is a non-optimistic split (it swaps after), sent through
    /// `DaemonService.perform` with the stand-in as its target. It is not sent (no DEBUG stop either) and the person sees
    /// the pane-still-opening notice exactly once.
    @Test func splitLeftOnAPendingSplitsPaneShowsOneNoticeAndSendsNothing() async throws {
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
            #expect(services.registry.perform("splitLeft", invocation: terminal))

            try await PinnedPageTests.until({ services.refusalHUD.shownCount > shown }, report: {
                "Split Left on the pending pane showed nothing (HUD \(services.refusalHUD.shownCount), was \(shown))"
            })
            #expect(services.refusalHUD.message?.contains(MiscHandlerStrings.paneNotReady) == true,
                    "the notice is not the pane-still-opening one: \(services.refusalHUD.message ?? "")")
            // The first split confirms; the refused Split Left made no third pane, and the notice showed once.
            try await PinnedPageTests.until({ content.panes.values.allSatisfy { $0.pane.handle.rawValue < ProvisionalPane.firstHandle } },
                                            report: { "the split did not confirm" })
            #expect(content.panes.count == before.count + 1, "Split Left made a pane: \(content.panes.count) panes")
            #expect(services.refusalHUD.shownCount == shown + 1, "the refusal showed \(services.refusalHUD.shownCount - shown) times")
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
            #expect(services.refusalHUD.message?.contains(MiscHandlerStrings.paneNotReady) == true,
                    "the notice is not the pane-still-opening one: \(services.refusalHUD.message ?? "")")
        }
    }

    /// Review #7 B1: a sender that calls the daemon connection itself, not a `DaemonService` funnel, shows the refusal
    /// too. A cmux.json `newTabInCurrentPane` command (`ConfigCommandRunner`, the typed New Tab page path) on a pending
    /// split's pane: the request is refused before it is sent, the notice shows once, and no tab opens.
    @Test func aCommandTypedIntoANewTabOnAPendingPaneShowsOneNotice() async throws {
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

            try await PinnedPageTests.until({ services.refusalHUD.shownCount > shown }, report: {
                "a typed new tab on the pending pane showed nothing (HUD \(services.refusalHUD.shownCount), was \(shown))"
            })
            #expect(services.refusalHUD.message?.contains(MiscHandlerStrings.paneNotReady) == true,
                    "the notice is not the pane-still-opening one: \(services.refusalHUD.message ?? "")")
            try await PinnedPageTests.until({ content.panes.values.allSatisfy { $0.pane.handle.rawValue < ProvisionalPane.firstHandle } },
                                            report: { "the split did not confirm" })
            let tabs = content.panes.values.reduce(0) { $0 + $1.pane.tabs.count }
            #expect(tabs == tabsBefore + 1, "the refused typed new tab opened a tab: \(tabs) tabs, \(tabsBefore) before the split")
            #expect(services.refusalHUD.shownCount == shown + 1, "the refusal showed \(services.refusalHUD.shownCount - shown) times")
        }
    }
}
