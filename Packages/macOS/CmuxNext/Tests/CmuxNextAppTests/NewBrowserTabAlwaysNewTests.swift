import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextTabs
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// New Browser Tab (Cmd-Shift-L, `openBrowser` with no URL) always opens the New Tab page. It used to open what the
/// selected tab worked on (#16620): a terminal's newest localhost URL, an agent chat's newest dev server or pull
/// request. Aziz 2026-11-06: "I just tried cmd shift L and it opened an old tab instead of making a new browser tab", and
/// "Cmd+Shift+L opens a browser tab prefilled with a dev build link that closes immediately" (a Tag Opener link, which
/// launches the build and closes its page).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewBrowserTabAlwaysNewTests {
    @Test func cmdShiftLBesideATerminalShowingADevServerOpensTheNewTabPage() async throws {
        try await Self.cmdShiftL(besideATerminalShowing: "Local: http://localhost:5173/", link: "localhost:5173")
    }

    @Test func cmdShiftLBesideATerminalShowingADevBuildLinkOpensTheNewTabPage() async throws {
        try await Self.cmdShiftL(besideATerminalShowing: "Tag Opener: http://127.0.0.1:17320/browser-pane-stuck", link: "127.0.0.1:17320")
    }

    /// A terminal tab is selected and shows `line` (with a link containing `link`); Cmd-Shift-L opens a new browser tab
    /// whose address, in the model and in its page, is not that link.
    private static func cmdShiftL(besideATerminalShowing line: String, link: String) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let paneModel = try #require(store.workspaces.first?.screens.first?.panes.first)
            let surface = try await connection.newTab(in: paneModel.handle).surface
            try await PinnedPageTests.until({ store.tab(surface: surface) != nil })
            let terminal = try #require(store.tab(surface: surface))
            let pane = try #require(services.paneController(for: paneModel))
            try await PinnedPageTests.until({ pane.orderedIDs.map(\.rawValue).contains(terminal.id) })
            pane.select(TabID(terminal.id))

            // The selected terminal shows the link, as `vite`, `next dev` or a dev build handoff print it.
            _ = try await connection.request(SendInputRequest(surface: surface, text: "printf '\(line)\\n'\r"))
            try await PinnedPageTests.until({
                services.cache.existingTerminal(terminal.id).flatMap { WorkingURL.devServer(in: $0.session.surfaceView.viewportText()) } != nil
            }, report: { "the terminal never showed \(line)" })

            let before = Set(pane.orderedIDs.map(\.rawValue))
            // Cmd-Shift-L: the keyboard's `openBrowser`, no URL, aimed at the focused pane.
            #expect(services.registry.perform("openBrowser", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .pane, id: paneModel.id), origin: .user)))
            try await PinnedPageTests.until({
                store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).contains { $0.kind == .browser && !before.contains($0.id) }
            }, report: { "no new browser tab" })
            let opened = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                .first { $0.kind == .browser && !before.contains($0.id) })
            let address = opened.url ?? ""
            #expect(!address.contains(link), "New Browser Tab opened the terminal's link (\(address)), not a new tab")
            if let page = services.cache.existingBrowser(opened.id) {
                let live = page.tab.state.url?.absoluteString ?? ""
                #expect(!live.contains(link), "the new tab's page loads the terminal's link (\(live))")
            }
        }
    }
}
