import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHome
import CmuxHomeCore
import Testing
import CmuxNextTestSupport

/// The real Cmd-F path through the whole app (`withApp`, a live cmux-tui), as MarkdownPageFindTests runs
/// Find on a Markdown page. The app's own panels outlive the test, so this suite has no window-leak check, and it
/// lives in its own file: HomeFindTests.swift opens windows, so WindowCleanupCoverageTests asks its suites for one.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HomeFindRouteTests {
    /// The real Cmd-F path: `find` from a person (Cmd-F, Edit > Find) with a Home tab focused opens its
    /// find bar with the field focused at once, the first press; `hideFind` closes it.
    @Test func cmdFInAHomeTabOpensItsFocusedFindBar() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            #expect(services.registry.perform("home.tab", invocation: ActionInvocation(origin: .user)))
            let pane = try #require(services.windows.active?.focusedPane)
            // A headless test window never draws the tab: the pane shows it here, as on screen.
            if pane.currentContent == nil { pane.showSelected() }
            @MainActor func page() -> TopHomePageView? {
                guard case .page(let view)? = pane.currentContent else { return nil }
                var stack: [NSView] = [view]
                while let next = stack.popLast() {
                    if let page = next as? TopHomePageView { return page }
                    stack.append(contentsOf: next.subviews)
                }
                return nil
            }
            try await PasswordManagerRouteTests.until({ page() != nil }, report: { "home.tab opened no Home tab in the focused pane" })
            // A fresh daemon has no conversation picked yet: the Home tab shows one, as a click in its list does.
            try #require(page()).show(ConversationID("conv_home_find_route"))
            @MainActor func transcript() -> HomeNativeTranscriptView? { page().flatMap { HomeNativeTranscriptView.first(in: $0) } }
            try await PasswordManagerRouteTests.until({ transcript()?.window != nil }, report: { "the Home tab shows no chat" })
            let home = try #require(transcript())
            let window = try #require(home.window)

            #expect(services.registry.perform("find", invocation: ActionInvocation(origin: .user)))
            guard let pill = home.findBar else { Issue.record("Cmd-F in the Home tab showed no find bar"); return }
            #expect(pill.isPresented)
            #expect(FindPillView.ownsFieldEditor(window.firstResponder), "the first Cmd-F did not focus the find field")

            _ = services.registry.perform("hideFind", invocation: ActionInvocation(origin: .user))
            #expect(!pill.isPresented, "hideFind left the Home find bar shown")
        }
    }
}
