import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-12: `pscale auth login` in a cmux-next terminal "failed to auto-open in
/// browser", and "it should ideally auto open in browser to the right". A terminal program's link
/// (`open URL`, `xdg-open`, `$BROWSER`: the bundled `cmux-open-url`, `browser.open_link`) that
/// opens without the focus (an agent's command, or a program whose output is not a terminal) was
/// made unselected behind the tab the pane on the right showed, so the sign-in page never showed;
/// with nothing on the right, its move to a new split could leave it in the terminal's own pane.
/// Such a page shows on the right, selected there, and the keyboard stays in the terminal.
/// Runs ``LinkRouter/openTerminalLink`` (every program link's path) against a same-tree daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct TerminalProgramLinkShowsTests {
    static let link = URL(string: "https://auth.example.test/oauth/device?user_code=ABCD-EFGH")!

    /// A browser pane already on the right: the page is a tab there, selected, and the terminal keeps the focus.
    @Test func aProgramsLinkWithoutTheFocusShowsInThePaneOnTheRight() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let source = try #require(model.tabs.first?.id)
            let right = try await Self.splitRightHoldingABrowser(services, content, connection)
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })
            services.linkOpener.placement = { .splitRight }

            let tab = try await Self.openProgramLink(services, from: source)
            try await PinnedPageTests.until({ right.pane.tabs.contains { $0.id == tab } },
                                            report: { "the program's page is not in the pane on the right: " + Self.describe(content) })
            try await PinnedPageTests.until({ right.stripModel.selectedID?.rawValue == tab },
                                            report: { "the program's page opened hidden in the pane on the right: " + Self.describe(content) })
            #expect(content.focusedPane === pane, "the program's page took the keyboard from its terminal: \(Self.describe(content))")
        }
    }

    /// Nothing on the right: the page opens in a new split there, never in the terminal's own pane.
    @Test func aProgramsLinkWithoutTheFocusSplitsRight() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let source = try #require(model.tabs.first?.id)
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })
            services.linkOpener.placement = { .splitRight }
            let panes = Set(content.panes.keys)

            let tab = try await Self.openProgramLink(services, from: source)
            @MainActor func shown() -> PaneController? {
                content.panes.first { !panes.contains($0.key) && $0.value.pane.tabs.contains { $0.id == tab } }?.value
            }
            try await PinnedPageTests.until({ shown()?.stripModel.selectedID?.rawValue == tab },
                                            report: { "the program's page is not shown in a new split on the right: " + Self.describe(content) })
            #expect(!pane.pane.tabs.contains { $0.id == tab }, "the program's page stayed in the terminal's pane: \(Self.describe(content))")
        }
    }

    /// `cmux open --link -` with no terminal waiting: `browser.open_link` with focus false. The daemon's new tab.
    private static func openProgramLink(_ services: AppServices, from source: String) async throws -> String {
        let store = services.daemon.store
        let before = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
        #expect(LinkRouter.shared.openTerminalLink(link, terminal: nil, source: source, explicit: true, background: true) == .cmuxBrowser)
        @MainActor func opened() -> String? {
            store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { !before.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }?.id
        }
        try await PinnedPageTests.until({ opened() != nil }, report: { "the program's link opened no tab" })
        return try #require(opened())
    }

    /// Splits the focused pane right and leaves one browser tab alone in the new pane once the daemon confirmed it.
    private static func splitRightHoldingABrowser(_ services: AppServices, _ content: WorkspaceContentController,
                                                  _ connection: DaemonConnection) async throws -> PaneController {
        let panes = Set(content.panes.keys)
        #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
        func confirmed() -> PaneController? {
            content.panes.first { !panes.contains($0.key) && $0.value.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }?.value
        }
        try await PinnedPageTests.until({ confirmed() != nil }, report: { "the split did not confirm" })
        let right = try #require(confirmed())
        let terminals = right.pane.tabs.map(\.surface).filter { !ProvisionalTab.isProvisional(surface: $0) }
        // A closed loopback port: the page never loads, and nothing leaves the machine.
        let browser = try await connection.newFrontendBrowserTab(url: "http://127.0.0.1:9/right", engine: .webkit, in: right.pane.handle, activate: true)
        try await PinnedPageTests.until({ right.pane.tabs.contains { $0.surface == browser.surface } },
                                        report: { "the pane on the right did not list its browser tab" })
        for terminal in terminals { try await connection.closeTab(terminal) }
        try await PinnedPageTests.until({ right.pane.tabs.map(\.surface) == [browser.surface] && content.panes[right.layoutPaneID] === right },
                                        report: { "the pane on the right does not hold its browser tab alone: " + describe(content) })
        return right
    }

    /// Each pane: focused or not, its selected tab and its tabs.
    private static func describe(_ content: WorkspaceContentController) -> String {
        let focused = content.focusedPane
        return content.panes.values.map { pane in
            "\(pane.layoutPaneID)\(pane === focused ? " (focused)" : ""): \(pane.stripModel.selectedID?.rawValue ?? "none") of \(pane.pane.tabs.map(\.id))"
        }.sorted().joined(separator: "; ")
    }
}
