import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// P0 STATUS 2080: Cmd-N, then Ctrl-` at once. The Ctrl-` targets Cmd-N's stand-in pane before the daemon's workspace
/// took it over; it was refused at once ("This pane is still opening; try again in a moment") and the window showed only
/// the New Tab page: no terminal in 20 s, in 4 of 4 quick journey rounds. The key belongs to the pane the person
/// pressed it in: the New Terminal Tab waits for Cmd-N's create and opens its terminal in the daemon's pane.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdNThenNewTerminalTabTests {
    @Test func newTerminalTabPressedOnCmdNsStandInOpensItsTerminalInTheNewWorkspace() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            // This Mac hosts the New Tab page, so Cmd-N takes the instant path (a stand-in workspace and pane).
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdn-ctrlbt")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let pid = try #require(services.daemon.identity?.pid)
            let store = services.daemon.store
            let before = Set(store.workspaces.map(\.id))
            let shown = services.refusalHUD.shownCount

            // The daemon answers nothing until both keys were handled, so Cmd-N's stand-in is still the target of the
            // Ctrl-` in every run (the person's quick Cmd-N + Ctrl-`), whatever the host's speed.
            #expect(kill(pid, SIGSTOP) == 0)
            var resumed = false
            defer { if !resumed { kill(pid, SIGCONT) } }
            var work = services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
            }
            let key = try #require(store.workspaces.first { !before.contains($0.id) }?.id, "Cmd-N showed no workspace in its turn")
            try await PasswordManagerRouteTests.until({
                services.windows.active?.workspaceContent?.workspace.id == key
                    && services.windows.active?.workspaceContent?.focusedPane != nil
            }, within: .seconds(2), report: { "the window does not show Cmd-N's workspace" })
            let content = try #require(services.windows.active?.workspaceContent)
            let standIn = try #require(content.focusedPane, "Cmd-N's workspace has no focused pane")
            #expect(standIn.pane.handle.rawValue >= ProvisionalPane.firstHandle, "Cmd-N's pane already confirmed: the race was not reached")
            work += services.registry.capturingWork {
                _ = services.registry.perform("newSurface", invocation: ActionInvocation(origin: .user))
            }
            #expect(kill(pid, SIGCONT) == 0)
            resumed = true

            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(failures.isEmpty, "the person's Cmd-N or Ctrl-` failed: \(failures)")

            // The new workspace is the daemon's, with its New Tab page and the new terminal tab, selected.
            @MainActor func terminal() -> (PaneModel, TabModel)? {
                guard let workspace = store.workspaces.first(where: { $0.id == key }), !workspace.isProvisional else { return nil }
                for pane in workspace.screens.flatMap(\.panes) where pane.handle.rawValue < ProvisionalPane.firstHandle {
                    if let tab = pane.tabs.first(where: { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }) { return (pane, tab) }
                }
                return nil
            }
            try await PasswordManagerRouteTests.until({ terminal() != nil }, report: {
                let tabs = store.workspaces.first { $0.id == key }?.screens.flatMap(\.panes).map { "\($0.handle.rawValue): \($0.tabs.map { "\($0.kind) \($0.surface.rawValue)" })" }
                return "no terminal in Cmd-N's workspace after Ctrl-`; panes \(String(describing: tabs)); failures \(failures); HUD \(services.refusalHUD.message ?? "none")"
            })
            let (pane, tab) = try #require(terminal())
            #expect(pane.tabs.contains { $0.kind == .conversation }, "the New Tab page left the pane: \(pane.tabs.map(\.kind))")
            #expect(services.refusalHUD.shownCount == shown,
                    "a refusal showed for the person's keys: \(services.refusalHUD.message ?? "")")
            try await PasswordManagerRouteTests.until({ services.paneController(for: pane)?.selectedTab === tab }, within: .seconds(5), report: {
                "the new terminal tab is not selected: \(String(describing: services.paneController(for: pane)?.selectedTab?.kind))"
            })
        }
    }

    /// The second refusal kind (the desync owner's probe, 16 of 20 lost presses; p0cb-head s4): the Ctrl-` reaches a
    /// pane controller that still shows Cmd-N's stand-in after the daemon's workspace took it over (a window one frame
    /// behind the store). It named nothing and failed as "the daemon refused the new tab" with no request sent; it must
    /// open its terminal in the daemon's pane.
    @Test func newTerminalTabOnCmdNsStandInAfterTheHandOverOpensInTheDaemonsPane() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdn-ctrlbt-late")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let pid = try #require(services.daemon.identity?.pid)
            let store = services.daemon.store
            let before = Set(store.workspaces.map(\.id))
            let shown = services.refusalHUD.shownCount

            // Cmd-N with the daemon stopped, so its stand-in pane's controller is caught before the hand-over.
            #expect(kill(pid, SIGSTOP) == 0)
            var resumed = false
            defer { if !resumed { kill(pid, SIGCONT) } }
            var work = services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
            }
            let key = try #require(store.workspaces.first { !before.contains($0.id) }?.id, "Cmd-N showed no workspace in its turn")
            try await PasswordManagerRouteTests.until({
                services.windows.active?.workspaceContent?.workspace.id == key
                    && services.windows.active?.workspaceContent?.focusedPane != nil
            }, within: .seconds(2), report: { "the window does not show Cmd-N's workspace" })
            let standIn = try #require(services.windows.active?.workspaceContent?.focusedPane)
            let standInHandle = standIn.pane.handle
            #expect(standInHandle.rawValue >= ProvisionalPane.firstHandle, "Cmd-N's pane already confirmed")
            #expect(kill(pid, SIGCONT) == 0)
            resumed = true

            // The daemon's workspace takes the stand-in over and Cmd-N's create ends.
            for task in work { _ = await task.value }
            try await PasswordManagerRouteTests.until({
                store.panesByHandle[standInHandle] == nil
                    && !store.pendingIntents.contains { if case .createWorkspace = $0.intent { true } else { false } }
            }, report: { "Cmd-N's create did not hand its stand-in over" })

            // The person's Ctrl-` reaches the controller that still shows the stand-in.
            work = services.registry.capturingWork { standIn.newTerminalTab(fromSelectedTab: true) }
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(failures.isEmpty, "the Ctrl-` on the handed-over stand-in failed: \(failures)")

            @MainActor func terminal() -> TabModel? {
                store.workspaces.first { $0.id == key }?.screens.flatMap(\.panes)
                    .flatMap(\.tabs).first { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
            }
            try await PasswordManagerRouteTests.until({ terminal() != nil }, report: {
                "no terminal in Cmd-N's workspace; failures \(failures); HUD \(services.refusalHUD.message ?? "none")"
            })
            #expect(services.refusalHUD.shownCount == shown, "a refusal showed: \(services.refusalHUD.message ?? "")")
        }
    }

    /// The keys the person types while the Ctrl-` waits for Cmd-N's create belong to the new terminal (coordinator
    /// 17:2xZ): the window's creation hold opens at the Ctrl-` press, not when the create is sent after the wait, and ends
    /// because the focus landed on the new terminal. The pass condition is what the person sees: every typed key reaches
    /// the NEW terminal, in order (its screen shows `echo held` and the shell's answer `held`), and no other terminal gets
    /// them. Each key goes through the app's own dispatch (`KeyRouter.interceptKeyDown`, then the window, as
    /// `CmuxApplication.sendEvent` does). On this dogfood line a key typed while the Ctrl-` stand-in terminal had the
    /// keyboard went to that view (107f5da1ac6, 050651b6e16), which sent it by a terminal id the daemon did not know yet
    /// (the create waits for Cmd-N's pane): lost. Now they wait in the creation hold, as on feat. How each key went is in the
    /// failure text, not the pass rule.
    @Test func keysTypedWhileCtrlBacktickWaitsForCmdNAreHeldForTheNewTerminal() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdn-ctrlbt-keys")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let pid = try #require(services.daemon.identity?.pid)
            let store = services.daemon.store
            let before = Set(store.workspaces.map(\.id))
            let coordinator = services.keyRouter.creationInputCoordinator
            // A held key runs again through the same key path as a typed one (the test window is never key).
            coordinator.replay = { event, window, router in if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) } }
            // Cmd-N's page hold keeps its keys while the page opens, as a person's does (this page never reports ready).
            services.keyRouter.newTabInputCoordinator.incomingHoldLimit = .seconds(120)

            #expect(kill(pid, SIGSTOP) == 0)
            var resumed = false
            defer { if !resumed { kill(pid, SIGCONT) } }
            var work = services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
            }
            let key = try #require(store.workspaces.first { !before.contains($0.id) }?.id, "Cmd-N showed no workspace in its turn")
            try await PasswordManagerRouteTests.until({
                services.windows.active?.workspaceContent?.workspace.id == key
                    && services.windows.active?.workspaceContent?.focusedPane != nil
            }, within: .seconds(2), report: { "the window does not show Cmd-N's workspace" })
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            #expect(try #require(content.focusedPane).pane.handle.rawValue >= ProvisionalPane.firstHandle, "Cmd-N's pane already confirmed")
            work += services.registry.capturingWork {
                _ = services.registry.perform("newSurface", invocation: ActionInvocation(origin: .user))
            }
            // In the press's turn, with the daemon still stopped: the hold is open; the keys typed now are the new terminal's.
            #expect(coordinator.isHolding(in: window), "no creation hold right after the Ctrl-`: the keys would go to the New Tab page")
            let router = services.keyRouter
            var paths: [String] = []
            for character in "echo held\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                // The app's dispatch: the key router first; a key it does not consume goes to the window's first responder.
                if router.interceptKeyDown(event, in: window) {
                    paths.append("\(text.debugDescription): consumed (dropped \(coordinator.droppedLastKey), held \(coordinator.heldCount(in: window)))")
                } else {
                    paths.append("\(text.debugDescription): to \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
                    window.sendEvent(event)
                }
            }
            #expect(kill(pid, SIGCONT) == 0)
            resumed = true

            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(failures.isEmpty, "the person's Cmd-N or Ctrl-` failed: \(failures)")
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) }, within: .seconds(10),
                                                      report: { "the creation hold never ended" })
            #expect(coordinator.lastHoldEnd(in: window) == .focusLanded,
                    "the hold ended by \(String(describing: coordinator.lastHoldEnd(in: window))), not because the new terminal got the focus")
            let selected = content.focusedPane?.selectedTab
            #expect(selected?.kind == .pty && selected.map { !ProvisionalTab.isProvisional(surface: $0.surface) } == true,
                    "the focused tab after the hold is not the new terminal: \(String(describing: selected?.kind))")

            // What the person sees: the new terminal shows the typed line and the shell ran it (every key, in order).
            let terminal = try #require(selected.flatMap { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) ? $0.surface : nil },
                                        "no new terminal to read; key paths: \(paths)")
            var screen = ""
            func ran(_ text: String) -> Bool {
                text.contains("echo held") && text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "held" }
            }
            let deadline = ContinuousClock.now + .seconds(30)
            while !ran(screen), ContinuousClock.now < deadline {
                screen = (try? await connection.request(ReadScreenRequest(surface: terminal), timeout: .seconds(2)).text) ?? screen
                if !ran(screen) { try await Task.sleep(for: .milliseconds(100)) }
            }
            #expect(ran(screen), "the new terminal did not get the typed line in order; its screen: \(screen.debugDescription); key paths: \(paths)")
            // No other terminal got the keys (the old workspace's terminal; a key can be in one place only, so the
            // New Tab page's composer had none of them either once the new terminal shows all ten).
            for other in store.panesByHandle.values.flatMap(\.tabs) where other.kind == .pty && other.surface != terminal
                && !ProvisionalTab.isProvisional(surface: other.surface) {
                let text = (try? await connection.request(ReadScreenRequest(surface: other.surface), timeout: .seconds(2)).text) ?? ""
                #expect(!text.contains("echo held"), "terminal \(other.surface) also got the typed line: \(text.debugDescription)")
            }
        }
    }
}
