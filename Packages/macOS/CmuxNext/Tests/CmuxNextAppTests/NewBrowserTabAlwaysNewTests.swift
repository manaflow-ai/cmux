import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// New Browser Tab (Cmd-Shift-L, `openBrowser` with no URL) always opens the New Tab page. It used to open what the
/// selected tab worked on (#16620): a terminal's newest localhost URL, an agent chat's newest dev server or pull
/// request. Aziz 2026-11-06: "I just tried cmd shift L and it opened an old tab instead of making a new browser tab."
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewBrowserTabAlwaysNewTests {
    @Test func cmdShiftLBesideATerminalShowingADevServerOpensTheNewTabPage() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let paneModel = try #require(store.workspaces.first?.screens.first?.panes.first)
            let surface = try await connection.newTab(in: paneModel.handle).surface
            try await PinnedPageTests.until({ store.tab(surface: surface) != nil })
            let terminal = try #require(store.tab(surface: surface))
            let pane = try #require(services.paneController(for: paneModel))
            try await PinnedPageTests.until({ pane.orderedIDs.map(\.rawValue).contains(terminal.id) })
            pane.select(TabID(terminal.id))

            // The selected terminal shows a dev server, as `vite` or `next dev` print it.
            let devServer = "http://localhost:5173/"
            _ = try await connection.request(SendInputRequest(surface: surface, text: "printf 'Local: \(devServer)\\n'\r"))
            try await PinnedPageTests.until({
                services.cache.existingTerminal(terminal.id).flatMap { WorkingURL.devServer(in: $0.session.surfaceView.viewportText()) } != nil
            }, report: { "the terminal never showed \(devServer)" })

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
            #expect(!address.contains("localhost"), "New Browser Tab opened the terminal's dev server (\(address)), not a new tab")
            if let page = services.cache.existingBrowser(opened.id) {
                let live = page.tab.state.url?.absoluteString ?? ""
                #expect(!live.contains("localhost"), "the new tab's page loads the terminal's dev server (\(live))")
            }
        }
    }
}
