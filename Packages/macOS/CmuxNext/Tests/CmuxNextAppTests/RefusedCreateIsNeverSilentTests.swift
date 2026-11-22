import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// P0 2026-10-30, rule (a): a refusal is never silent. A person's split the daemon refuses rolls its stand-in back and
/// shows the refusal where refusals show (the refusal HUD, with a log line). Before, it was only logged: the second
/// quick Cmd-D's pane just vanished (red bc0806423c73: `refusals []`).
///
/// The daemon refuses a split only for its own reasons (an unknown pane, a client id it holds), so the test makes one
/// without any timing: the split waits behind the workspace's create chain (`pendingCreate`), the daemon closes its
/// target pane meanwhile, then the split goes out and is refused ("unknown pane").
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct RefusedCreateIsNeverSilentTests {
    @Test func aSplitTheDaemonRefusesShowsItsRefusalAndLeavesNoStandIn() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            let before = Set(content.panes.keys)
            #expect(services.registry.perform("splitDown", invocation: terminal))
            @MainActor func confirmedNew() -> PaneController? {
                content.panes.first { !before.contains($0.key) && $0.value.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }?.value
            }
            try await PinnedPageTests.until({ confirmedNew() != nil }, report: { "the first split did not confirm" })
            let target = try #require(confirmedNew())
            PaneHandlers.focus(target.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === target }, report: { "the new pane did not take the focus" })
            let handle = target.pane.handle

            // Hold the next create in the chain until the daemon has closed its target.
            let (gate, open) = AsyncStream<Void>.makeStream()
            content.pendingCreate = Task { for await _ in gate { break }; return nil }
            let shown = services.refusalHUD.shownCount
            #expect(services.registry.perform("splitDown", invocation: terminal))
            try await connection.closePane(handle, endTerminals: true)
            open.yield()
            open.finish()

            try await PinnedPageTests.until({ services.refusalHUD.shownCount > shown }, report: {
                "the refused split showed nothing (HUD shown \(services.refusalHUD.shownCount), was \(shown))"
            })
            #expect(services.refusalHUD.message?.isEmpty == false, "the refusal HUD shows no text")
            try await PinnedPageTests.until({
                content.panes.values.allSatisfy { $0.pane.tabs.allSatisfy { !ProvisionalTab.isProvisional(surface: $0.surface) } }
                    && services.daemon.store.workspaces.allSatisfy { $0.screens.allSatisfy { $0.panes.allSatisfy { $0.handle.rawValue < ProvisionalPane.firstHandle } } }
            }, report: { "a stand-in stayed after the refusal: panes \(content.panes.map { "\($0.key): \($0.value.pane.handle.rawValue)" })" })
        }
    }
}
