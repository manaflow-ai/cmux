import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Smoke step 23 ("Cmd-D twice fast: two new panes, and the line typed into each at once ran there"): the second
/// Cmd-D's line ran in the FIRST new terminal. Fleet diag (10 loops of Cmd-D, a line, Cmd-D, a line, hog +15 GB) on the
/// tip b732874bf5e3: 3 of 4 rounds failed, and in each failing loop the focus generation rose by one less than in a
/// passing loop: the second split began no focus intent and opened no key hold. An optimistic split's pane record
/// takes the daemon's handle in place when the daemon's echo comes (`DaemonStore.confirmedPane`); the window's handle
/// map follows on its next topology apply. A Cmd-D in that step looked up the focused pane's controller by the new
/// handle, found none, and split with no focus and no hold, so the keys typed after it went to the first new terminal.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitOnEchoedPaneTests {
    @Test func cmdDOnAPaneWhoseRecordTookTheDaemonsHandleMovesTheFocusAndHoldsTheKeys() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            let coordinator = services.keyRouter.creationInputCoordinator
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true

            // The first Cmd-D: a confirmed terminal pane, focused, its hold over.
            let before = Set(content.panes.keys)
            #expect(services.registry.perform("splitRight", invocation: terminal))
            @MainActor func made() -> PaneController? { content.panes.filter { !before.contains($0.key) }.values.first }
            try await PinnedPageTests.until({ made().map { content.focusedPane === $0 && $0.pane.tabs.contains { $0.kind == .pty } } == true
                                                && !coordinator.isHolding(in: window) && content.focus.state.expectation == nil },
                                            report: { "the first split's pane did not settle: panes \(content.panes.keys.sorted()), focus \(content.focus.state.resolved)" })
            let first = try #require(made())

            // The step after the daemon's echo: its pane record carries the daemon's handle, the window's map the old one.
            let shown = first.pane.handle
            first.pane.handle = PaneID(rawValue: shown.rawValue + 10_000)
            defer { first.pane.handle = shown }
            #expect(services.paneController(for: first.pane) === first, "the pane's own controller is not found for its record")

            // The second Cmd-D in that step: it moves the focus to its new pane and holds the keys typed for it.
            let generation = content.focus.state.generation
            #expect(services.registry.perform("splitRight", invocation: terminal))
            #expect(content.focus.state.generation > generation, "the second split began no focus intent (generation \(generation))")
            #expect(coordinator.isHolding(in: window), "the second split opened no key hold: its keys go to the first new terminal")
        }
    }
}
