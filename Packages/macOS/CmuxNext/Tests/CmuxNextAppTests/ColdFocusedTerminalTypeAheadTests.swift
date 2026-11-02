import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// REOPEN-F4 on the dogfood line (review of #32207, B1): a workspace shown cold (its view and its terminal's surface
/// went, as after a relaunch or a reopen) gives the keyboard to its focused terminal, and a plain key typed before that
/// terminal's surface shows waits for it and reaches it, in order. On this line a typing key in normal mode (no key
/// router mode on) went straight to the window's first responder, before the window's key hold could take it: the
/// focus named the restored terminal, its surface came on a later frame, and the key went to no view.
///
/// The test brings the first workspace back cold with the frame's surface budget already spent, so its terminal's surface is
/// not shown in the turn the window shows it, and types a line in that same turn. The keys go through the app's key
/// path (the key router, then the window); a held key runs again the same way (the test window is never key).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ColdFocusedTerminalTypeAheadTests {
    private typealias Terminal = (pane: String, tab: String, surface: SurfaceID)

    /// A pane that spends the frame's one new surface (``ContentPresentationScheduler``).
    @MainActor private final class BudgetSpender: PresentablePane {
        var selectedContentIsAlive: Bool { false }
        var isFocusedInWorkspace: Bool { false }
        func showSelected() {}
    }

    @Test func aPlainLineTypedAsAColdWorkspaceShowsReachesItsFocusedTerminalInOrder() async throws {
        try await PinnedPageTests.withApp { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let router = services.keyRouter, coordinator = router.creationInputCoordinator
            coordinator.replay = { event, window, router in if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) } }
            let first = try #require(controller.state.workspaceID)

            @MainActor func terminal(of id: String) -> Terminal? {
                guard let content = controller.workspaceContent, content.workspace.id == id else { return nil }
                return content.panes.values.lazy.compactMap { pane -> Terminal? in
                    guard pane.pane.handle.rawValue < ProvisionalPane.firstHandle, let tab = pane.currentTabKey, case .terminal? = pane.currentContent,
                          let model = pane.pane.tabs.first(where: { $0.id == tab && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) })
                    else { return nil }
                    return (pane.paneKey, tab, model.surface)
                }.first
            }
            @MainActor func describe() -> String {
                "workspace \(controller.workspaceContent?.workspace.id ?? "-") panes \(controller.workspaceContent?.panes.values.map { "\($0.paneKey): \($0.currentTabKey ?? "-")" } ?? [])"
                    + " focus \(controller.focus.state.resolved) first responder \(String(describing: window.firstResponder))"
            }
            /// Workspace `id` shown with a terminal; a person's Ctrl-` makes one when it shows only a page (a Home or New Tab page).
            @MainActor func show(_ id: String) async throws -> Terminal {
                try await PinnedPageTests.until({
                    if controller.workspaceContent?.workspace.id != id { services.windows.show(workspaceID: id, in: controller.state) }
                    return controller.workspaceContent?.workspace.id == id && controller.workspaceContent?.panes.isEmpty == false
                }, within: .seconds(30), report: { "waiting for workspace \(id): \(describe())" })
                try? await PinnedPageTests.until({ terminal(of: id) != nil }, within: .seconds(5))
                if terminal(of: id) == nil { _ = services.registry.perform("newSurface", invocation: ActionInvocation(origin: .user)) }
                try await PinnedPageTests.until({ terminal(of: id) != nil }, within: .seconds(30), report: { "waiting for workspace \(id)'s terminal: \(describe())" })
                return try #require(terminal(of: id))
            }
            func screen(_ surface: SurfaceID) async -> String {
                (try? await connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(2)).text) ?? ""
            }
            func until(_ surface: SurfaceID, shows text: String, within limit: Duration) async -> String {
                var shown = await screen(surface)
                let deadline = ContinuousClock.now + limit
                while !shown.contains(text), ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                    shown = await screen(surface)
                }
                return shown
            }

            // The first workspace's terminal gets the keyboard; its shell is ready before anything is typed.
            let cold = first
            let typed = try await show(cold)
            try await PinnedPageTests.until({ controller.focus.state.resolved == .terminal(pane: typed.pane, tab: typed.tab)
                    && (window.firstResponder as? NSView)?.isDescendant(of: controller.workspaceContent?.paneController(key: typed.pane)?.view ?? NSView()) == true },
                report: { "waiting for the keyboard on the first terminal: \(describe())" })
            try await PinnedPageTests.until({ !coordinator.isHolding(in: window) }, report: { "waiting for the launch's hold to end" })
            try await connection.send(typed.surface, text: "echo ready$((3*3))\r")
            #expect(await until(typed.surface, shows: "ready9", within: .seconds(20)).contains("ready9"), "the shell of \(typed.tab) never answered")

            // A second workspace (on this line it opens a New Tab page); the first one's view and its terminal's surface
            // go (it comes back cold).
            let other = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: NSTemporaryDirectory(), name: "reopen-f4-other"), into: controller.state.id)
            try await PinnedPageTests.until({
                if controller.workspaceContent?.workspace.id != other { services.windows.show(workspaceID: other, in: controller.state) }
                return controller.workspaceContent?.workspace.id == other && controller.workspaceContent?.panes.isEmpty == false
            }, within: .seconds(30), report: { "waiting for the other workspace: \(describe())" })
            #expect(controller.discardParkedWorkspace(cold), "the first workspace was not parked: \(describe())")
            services.cache.discardTerminal(typed.tab)
            #expect(!services.cache.hasContent(for: typed.tab), "the first workspace's terminal kept its surface")

            // In one turn: the frame's surface budget is spent, the workspace shows cold, and the line is typed.
            let nonce = String(UInt32.random(in: 100_000...999_999))
            _ = services.presentation.showNow(BudgetSpender()) // false: another pane spent it already
            services.windows.show(workspaceID: cold, in: controller.state)
            #expect(controller.workspaceContent?.workspace.id == cold, "the window did not show the workspace in this turn")
            #expect(controller.focus.currentState().resolved == .terminal(pane: typed.pane, tab: typed.tab),
                    "the cold workspace's focus is not its remembered terminal: \(controller.focus.state.resolved)")
            #expect(!services.cache.hasContent(for: typed.tab), "the focused terminal's surface already shows: the test types too late")
            #expect(router.modes.isNormal, "a key router mode is on: the plain keys would not take the normal-mode path this test is about")
            var paths: [String] = []
            for character in "echo f4\(nonce)x$((6*7))\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                if router.interceptKeyDown(event, in: window) {
                    paths.append("\(text.debugDescription): held")
                } else {
                    paths.append("\(text.debugDescription): to \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
                    window.sendEvent(event)
                }
            }

            let shown = await until(typed.surface, shows: "f4\(nonce)x42", within: .seconds(15))
            #expect(shown.contains("f4\(nonce)x42"), "the line typed as the workspace showed never ran whole in its focused terminal: \(shown)\n\(describe())\nkey paths: \(paths)")
            #expect(shown.contains("echo f4\(nonce)x$((6*7))"), "the focused terminal's line is not the typed line, in order: \(shown)")
            for tab in services.daemon.store.panesByHandle.values.flatMap(\.tabs) where tab.kind == .pty && tab.surface != typed.surface
                && !ProvisionalTab.isProvisional(surface: tab.surface) {
                #expect(!(await screen(tab.surface)).contains("f4\(nonce)"), "keys typed for the cold workspace's terminal reached terminal \(tab.surface)")
            }
        }
    }
}
