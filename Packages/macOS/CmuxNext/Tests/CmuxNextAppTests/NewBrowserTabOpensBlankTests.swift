import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing

/// #37384: New Browser Tab (Cmd-Shift-L) opens a new blank browser tab, whatever the selected tab
/// shows. It used to open the newest localhost address on a selected terminal's screen (or an agent
/// chat's newest dev server): after an agent printed a dev build's Tag Opener link, every new browser
/// opened that link, which looked like the last closed tab coming back. Only Reopen Closed Tab brings
/// a closed tab's address back. Runs the app's `openBrowser` against a same-tree cmux-tui daemon, on a
/// live terminal whose screen shows the address.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewBrowserTabOpensBlankTests {
    @Test func newBrowserTabFromATerminalShowingALocalhostLinkOpensBlank() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let store = services.daemon.store
            let paneModel = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: paneModel))
            // A live terminal tab of the pane, selected and shown (as CmdWIdleTerminalClosesInItsTurnTests makes one).
            let surface = try await connection.newTab(in: paneModel.handle).surface
            try await PasswordManagerRouteTests.until({ store.tab(surface: surface) != nil })
            let terminal = try #require(store.tab(surface: surface))
            try await PasswordManagerRouteTests.until({ pane.orderedIDs.map(\.rawValue).contains(terminal.id) },
                                                      report: { "strip: \(pane.orderedIDs.map(\.rawValue))" })
            pane.select(StripTabID(terminal.id))
            try await PasswordManagerRouteTests.until({ services.cache.existingTerminal(terminal.id) != nil },
                                                      report: { "the terminal's view was never made" })
            // A dev build's Tag Opener link on the terminal's screen, as an agent prints it.
            let link = "http://127.0.0.1:17320/37384-new-browser-blank"
            _ = try await connection.request(SendInputRequest(surface: terminal.surface, text: "printf '%s\\n' '\(link)'\r"))
            @MainActor func screen() -> String { services.cache.existingTerminal(terminal.id)?.session.surfaceView.viewportText() ?? "" }
            try await PasswordManagerRouteTests.until({ screen().contains(link) }, report: { "the terminal shows: \(screen().suffix(400))" })

            let before = Set(paneModel.tabs.map(\.id))
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: paneModel.id),
                                              arguments: ["engine": .string(BrowserEngineTag.webkit.rawValue)], origin: .user)
            #expect(services.registry.perform("openBrowser", invocation: invocation))
            @MainActor func added() -> [TabModel] {
                store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                    .filter { $0.kind == .browser && !before.contains($0.id) && !ProvisionalTab.isProvisional(surface: $0.surface) }
            }
            try await PasswordManagerRouteTests.until({ !added().isEmpty }, report: { "no browser tab: \(PasswordManagerRouteTests.tabs(services).map { "\($0.kind) \($0.url ?? "-")" })" })
            let opened = try #require(added().first)
            #expect(added().count == 1)
            // The New Tab page, or the page `browser.newTabPage` names when it is set.
            let configured = services.settings?.snapshot.browserNewTabPage?.absoluteString
            #expect(BrowserNewTabPage.isNewTabPage(opened.url ?? "") || (configured != nil && opened.url == configured),
                    "New Browser Tab opened \(opened.url ?? "nothing"), not a blank tab")
            #expect(opened.url?.contains("17320") != true, "New Browser Tab opened the terminal's localhost link")
        }
    }
}
