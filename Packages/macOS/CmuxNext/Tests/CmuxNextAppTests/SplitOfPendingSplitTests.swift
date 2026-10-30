import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// P0 2026-10-30 ("at some points I can no longer make new terminals via Ctrl-` or Cmd-D"), bench-arms run
/// 02dcba2e1c9e447c7cad0594: in a quick pair of splits the second Cmd-D made no pane within 5 s, 12 of 12. The first
/// split's pane shows and takes focus in the key's frame (a stand-in, `ProvisionalPane`) before the daemon made it;
/// a second Cmd-D on it, while that reply is pending, must still give a second terminal pane that takes the keys.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitOfPendingSplitTests {
    @Test func aSecondSplitOnAPendingSplitsPaneMakesASecondPane() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            let before = Set(content.panes.keys)
            var refusals: [String] = []
            let previous = services.registry.refusalObserver
            services.registry.refusalObserver = { reason, quiet in refusals.append(reason); previous?(reason, quiet) }
            defer { services.registry.refusalObserver = previous }

            // One main-actor turn, no await: the first split's reply cannot have come, and its stand-in has the focus.
            #expect(services.registry.perform("splitDown", invocation: terminal))
            let first = try #require(content.panes.first { !before.contains($0.key) }?.value, "the first split shows no pane in its turn")
            #expect(first.pane.tabs.allSatisfy { ProvisionalTab.isProvisional(surface: $0.surface) }, "the first split already confirmed")
            PaneHandlers.focus(first.layoutPaneID, in: content)
            #expect(services.registry.perform("splitDown", invocation: terminal))

            func confirmed() -> [PaneController] {
                content.panes.filter { !before.contains($0.key) }.map(\.value)
                    .filter { $0.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) } }
            }
            try await PinnedPageTests.until({ confirmed().count == 2 }, report: {
                "new confirmed terminal panes \(confirmed().count) of 2; panes \(content.panes.count); refusals \(refusals)"
            })
            #expect(refusals.isEmpty, "a split was refused: \(refusals)")
            let second = try #require(confirmed().first { $0 !== first && $0.layoutPaneID != first.layoutPaneID })
            try await PinnedPageTests.until({ content.focusedPane === second }, report: {
                "focused \(String(describing: content.focusedPane?.paneKey)), wanted the second split's pane \(second.paneKey)"
            })
        }
    }
}
