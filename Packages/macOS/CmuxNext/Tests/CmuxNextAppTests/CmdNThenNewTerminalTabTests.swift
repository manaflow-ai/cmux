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
}
