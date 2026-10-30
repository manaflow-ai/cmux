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
            // The test host runs in English; the text is MiscHandlerStrings.paneNotReady.
            #expect(notice.localizedCaseInsensitiveContains("still opening"), "the notice is not the pane-still-opening one: \(notice)")
            #expect(!notice.localizedCaseInsensitiveContains("unknown pane"), "the stand-in reached the daemon: \(notice)")
            // The split confirms; nothing was zoomed.
            try await PinnedPageTests.until({ content.panes.values.allSatisfy { $0.pane.handle.rawValue < ProvisionalPane.firstHandle } },
                                            report: { "the split did not confirm" })
            #expect(services.daemon.store.workspaces.allSatisfy { $0.screens.allSatisfy { $0.zoomedPane == nil } },
                    "a pane was zoomed after a refused zoom")
        }
    }
}
