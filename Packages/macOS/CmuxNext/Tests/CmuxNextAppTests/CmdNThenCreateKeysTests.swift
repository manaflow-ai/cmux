import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTerminal
import Darwin
import Foundation
import Testing

/// Judged smoke of dogfood v2.2.13-opt, round 2 step 16 (PR #30271): after Cmd-N, Ctrl-` and a typed line, the line's
/// keys went to the New Tab page, not the new terminal. Cmd-N opens the window's New Tab hold (`beginIncoming`): every
/// key waits for the new page's field. A Ctrl-` (or Cmd-D) pressed then is the person's newer intent, but nothing ended
/// that hold, so the keys typed after it still waited for the page and went to its field. The pass condition is what
/// the person sees: every typed key reaches the NEW terminal, in order (its screen shows `echo held` and the shell's
/// answer `held`), and no other terminal gets them. Each key goes through the app's dispatch (`KeyRouter.interceptKeyDown`,
/// then the window), and a held key runs again the same way (the test window is never key). Port of #30827.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdNThenCreateKeysTests {
    @Test func keysTypedAfterCmdNThenCtrlBacktickReachTheNewTerminal() async throws {
        try await Self.typeAfterCmdN(then: "newSurface", invocation: ActionInvocation(origin: .user))
    }

    /// The same seam for Cmd-D (a split that opens a terminal): its creation hold takes the keys from the page's hold.
    @Test func keysTypedAfterCmdNThenCmdDReachTheNewTerminal() async throws {
        var terminal = ActionInvocation(origin: .user)
        terminal.opensTerminal = true
        try await Self.typeAfterCmdN(then: "splitDown", invocation: terminal)
    }

    /// Where a key goes now (diagnostics): the first responder, whether it is the focused pane's shown terminal view, that
    /// view's tab, its stand-in gate and the terminal id it sends by while its terminal is still being created.
    private static func where_(_ window: NSWindow, services: AppServices, consumed: Bool) -> String {
        let responder = window.firstResponder.map { "\(type(of: $0))@\(ObjectIdentifier($0).hashValue & 0xffff)" } ?? "none"
        guard let content = services.windows.active?.workspaceContent, let pane = content.focusedPane else { return "consumed \(consumed), responder \(responder), no focused pane" }
        let tab = pane.currentTabKey ?? "-"
        guard case .terminal(let entry)? = pane.currentContent else { return "consumed \(consumed), responder \(responder), pane \(pane.pane.handle.rawValue) shows \(tab), no terminal" }
        let isView = (window.firstResponder as? NSView).map { $0 === entry.session.surfaceView || $0.isDescendant(of: entry.session.view) } ?? false
        return "consumed \(consumed), responder \(responder) isShownTerminal \(isView), pane \(pane.pane.handle.rawValue), tab \(tab), "
            + "gate \(entry.gate.map { $0.isResolved ? "resolved" : "open" } ?? "none"), creatingTerminalID \(entry.io.creatingTerminalID ?? "-"), "
            + "focus \(content.focus.state.resolved)"
    }

    /// Cmd-N with the daemon stopped (its workspace stays a stand-in), then `action`, then "echo held" Return, each key
    /// through the app's dispatch; then the daemon runs, and the new terminal must show the line and its answer.
    private static func typeAfterCmdN(then action: ActionID, invocation: ActionInvocation) async throws {
        // Terminal views type through their Ghostty surface: without a started runtime they have none, and no key reaches
        // the PTY (diagnostic 12f65c19335cf44d44de0317: a control line typed after the hold did not show either).
        GhosttyRuntime.startedForTests()
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdn-create-keys")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let pid = try #require(services.daemon.identity?.pid)
            let store = services.daemon.store
            let before = Set(store.workspaces.map(\.id))
            let router = services.keyRouter
            let coordinator = router.creationInputCoordinator
            // A held key runs again through the same key path as a typed one (the test window is never key). Diagnostics
            // (#30271, lead 14:43Z): where each replayed key went, by responder, focus, tab and terminal ids.
            var replays: [String] = []
            coordinator.replay = { event, window, router in
                let consumed = router.interceptKeyDown(event, in: window)
                replays.append("\((event.characters ?? "").debugDescription): " + Self.where_(window, services: services, consumed: consumed))
                if !consumed { window.sendEvent(event) }
            }
            // The page's hold keeps its keys as long as the page is opening, as for a person: their New Tab page reports
            // its field ready and takes the keys (smoke step 16). This harness's page never reports ready, so its 4 s
            // bound would hand the keys on and hide the loss (red 808acd14 passed on the base for that reason).
            router.newTabInputCoordinator.incomingHoldLimit = .seconds(120)

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
            work += services.registry.capturingWork { _ = services.registry.perform(action, invocation: invocation) }
            var paths: [String] = []
            for character in "echo held\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                if router.interceptKeyDown(event, in: window) {
                    paths.append("\(text.debugDescription): consumed (creation hold \(coordinator.isHolding(in: window)), "
                        + "New Tab hold \(router.newTabInputCoordinator.isHolding(in: window)))")
                } else {
                    paths.append("\(text.debugDescription): to \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
                    window.sendEvent(event)
                }
            }
            #expect(kill(pid, SIGCONT) == 0)
            resumed = true

            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(failures.isEmpty, "\(action): the person's Cmd-N or \(action) failed: \(failures)")
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) }, within: .seconds(10),
                                                      report: { "\(action): the creation hold never ended" })
            let selected = content.focusedPane?.selectedTab
            let terminal = try #require(selected.flatMap { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) ? $0.surface : nil },
                                        "\(action): the focused tab is not the new terminal (\(String(describing: selected?.kind))); key paths: \(paths)")

            // What the person sees: the new terminal shows the typed line and the shell ran it (every key, in order).
            func ran(_ text: String) -> Bool {
                text.contains("echo held") && text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "held" }
            }
            var screen = ""
            let deadline = ContinuousClock.now + .seconds(15)
            while !ran(screen), ContinuousClock.now < deadline {
                screen = (try? await connection.request(ReadScreenRequest(surface: terminal), timeout: .seconds(2)).text) ?? screen
                if !ran(screen) { try await Task.sleep(for: .milliseconds(100)) }
            }
            if !ran(screen) {
                // Control: one line typed now, with no hold, through the same dispatch into the focused terminal.
                let after = Self.where_(window, services: services, consumed: false)
                for character in "echo ctl\r" {
                    let text = String(character)
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                                                    isARepeat: false, keyCode: text == "\r" ? 36 : 0),
                       !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
                }
                try await Task.sleep(for: .seconds(3))
                let control = (try? await connection.request(ReadScreenRequest(surface: terminal), timeout: .seconds(2)).text) ?? "?"
                let diag: String = "\(action): DIAG terminal \(terminal) (tab terminal id \(selected?.terminalID?.rawValue ?? "-")); replays \(replays); "
                    + "after the hold: \(after); control line typed then: screen \(control.debugDescription)"
                Issue.record(Comment(rawValue: diag))
            }
            #expect(ran(screen), "\(action): the new terminal did not get the typed line in order; its screen: \(screen.debugDescription); key paths: \(paths)")
            // No other terminal got the line.
            for other in store.panesByHandle.values.flatMap(\.tabs) where other.kind == .pty && other.surface != terminal
                && !ProvisionalTab.isProvisional(surface: other.surface) {
                let text = (try? await connection.request(ReadScreenRequest(surface: other.surface), timeout: .seconds(2)).text) ?? ""
                #expect(!text.contains("echo held"), "\(action): terminal \(other.surface) also got the typed line: \(text.debugDescription)")
            }
        }
    }
}
