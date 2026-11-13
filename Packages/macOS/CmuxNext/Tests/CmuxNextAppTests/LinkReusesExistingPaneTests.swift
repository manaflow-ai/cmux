import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Aziz 2026-11-09: "when I open a browser link, it shouldn't open in a new pane if there already exists another
/// pane. Mimic classic cmux behavior in cmux next." Classic cmux (`openTerminalBrowserLink`,
/// `BrowserRightSidePaneResolver`) opens a link as a new tab in the pane already on the source's right; it only
/// splits when nothing is there. cmux-next split below a right pane that held no browser yet (a terminal), so a
/// link Cmd-clicked in one of two side-by-side terminals made a third pane. Runs ``LinkOpener`` against a
/// same-tree cmux-tui daemon in a window wide enough that the old rule's lower split fits (480 pt source, 420 pt
/// right pane: below that the old rule was a tab too, so the host's window decided, ClickedLinkFocusTests).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct LinkReusesExistingPaneTests {
    static let link = URL(string: "https://example.com/link-reuses-pane")!

    /// Two terminals side by side (Cmd-D); a link opened from the left one (`openWeb`, as a terminal's Cmd-click
    /// opens it) is a tab in the right terminal's pane, and the screen keeps its two panes.
    @Test func aLinkBesideATerminalOpensAsATabInThePaneOnTheRight() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let (content, left, right) = try await Self.twoTerminals(services)
            let store = services.daemon.store
            let before = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))

            #expect(services.linkOpener.openWeb(Self.link, from: left, background: false))

            @MainActor func opened() -> TabModel? {
                store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                    .first { !before.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }
            }
            try await PinnedPageTests.until({ opened() != nil }, report: { "the link opened no tab: " + Self.describe(content) })
            let tab = try #require(opened())
            #expect(right.pane.tabs.contains { $0.id == tab.id }, "the link's tab is not in the pane on the right: \(Self.describe(content))")
            #expect(content.panes.count == 2, "the link made a new pane: \(Self.describe(content))")
            #expect(!left.pane.tabs.contains { $0.id == tab.id }, "the link's tab stayed in the terminal it was clicked in")
        }
    }

    /// A browser the person asks for that is not a link (a dock's Browser button, a New Tab page pick) keeps Leo's
    /// lower split beside a terminal (2026-10-31: split "when there's a terminal that gets opened when there's
    /// already a browser, and vice versa"); only links reuse the pane. Both read the same layout, and the second
    /// proves the window is wide enough for the old rule to split.
    @Test func onlyALinkReusesThePaneABrowserStillSplitsBelow() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let (content, left, right) = try await Self.twoTerminals(services)
            #expect(services.linkOpener.target(from: left, kind: .browser, link: true) == .pane(right.layoutPaneID),
                    "a link beside the terminal splits: \(Self.describe(content))")
            #expect(services.linkOpener.target(from: left, kind: .browser) == .splitBelow(of: right.layoutPaneID),
                    "the window is too narrow for the lower split, so this cannot tell the rules apart: \(Self.describe(content))")
        }
    }

    /// The window's first terminal, then Split Right (a terminal in the new pane), in an 1800 pt window; focus back on the left.
    private static func twoTerminals(_ services: AppServices) async throws -> (WorkspaceContentController, PaneController, PaneController) {
        let controller = try #require(services.windows.active)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1800, height: 1000), display: false)
        let content = try #require(controller.workspaceContent)
        let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let left = try #require(services.paneController(for: model))
        PaneHandlers.focus(left.layoutPaneID, in: content)
        try await PinnedPageTests.until({ content.focusedPane === left })
        let panes = Set(content.panes.keys)
        #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
        func confirmed() -> PaneController? {
            content.panes.first { !panes.contains($0.key) && $0.value.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }?.value
        }
        try await PinnedPageTests.until({ confirmed() != nil }, report: { "the split did not confirm" })
        let right = try #require(confirmed())
        content.contentView.layoutSubtreeIfNeeded()
        PaneHandlers.focus(left.layoutPaneID, in: content)
        try await PinnedPageTests.until({ content.focusedPane === left })
        services.linkOpener.placement = { .splitRight }
        return (content, left, right)
    }

    private static func describe(_ content: WorkspaceContentController) -> String {
        content.panes.values.map { pane in
            "\(pane.layoutPaneID) \(Int(pane.view.bounds.width)) pt wide: \(pane.pane.tabs.map { "\($0.kind)" })"
        }.sorted().joined(separator: "; ")
    }
}
