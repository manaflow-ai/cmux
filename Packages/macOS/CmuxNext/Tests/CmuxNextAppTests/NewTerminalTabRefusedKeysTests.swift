import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// CREATION HOLD NO-LANE KEYS. The person presses Ctrl-` (New Terminal Tab) in a terminal and types a line with Return
/// for the new terminal. The window's creation hold keeps the line until the daemon answers the create. When the daemon
/// refuses the tab, the new terminal never exists, and the line must run in no terminal. The hold's ticket had no lane
/// (no tab), so each of its keys ended as "run again as typed" in what has the keyboard: after the stand-in went away
/// that was the terminal the person pressed Ctrl-` in, and its shell ran a line typed for another terminal.
///
/// The app runs on a same-tree cmux-tui through a proxy that holds the tab's create while a file exists and then answers
/// it `ok:false` itself. As an older daemon the proxy also takes `terminal-placement-env-v1` out of what the daemon says
/// it can do: New Terminal Tab then shows no stand-in and waits for the create (`create-terminal`, then a move).
///
/// The keys go through the app's key path (the key router, then the window's first responder). A test window is never
/// key, so a held key that runs again goes the same way here, not through `NSApp.sendEvent`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTerminalTabRefusedKeysTests {
    /// The daemon behind the proxy: as it is, or as one from before `terminal-placement-env-v1`.
    nonisolated enum Daemon: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case current, older
        var testDescription: String { rawValue }
    }

    /// The capability by its wire name.
    static let capability = "terminal-placement-env-v1"

    nonisolated static let proxy = #"""
    import json, os, socket, sys, threading, time
    path, hold, log, older = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == 'older'
    daemon = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    daemon.connect(path)
    print('{"ok":true}', file=sys.stderr, flush=True)
    lock, out, held = threading.Lock(), threading.Lock(), []
    def to_app(line):
        with out:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
    def to_daemon():
        for line in sys.stdin.buffer:
            try:
                frame = json.loads(line)
            except ValueError:
                frame = {}
            with lock:
                if isinstance(frame, dict) and frame.get('cmd') in ('new-tab', 'create-terminal') and os.path.exists(hold):
                    held.append(frame)
                    continue
                daemon.sendall(line)
        daemon.shutdown(socket.SHUT_WR)
    def refuse():
        while True:
            time.sleep(0.02)
            with lock:
                if held and not os.path.exists(hold):
                    for frame in held:
                        reply = {'id': frame.get('id'), 'ok': False, 'error': 'refused by the proxy of the test'}
                        to_app((json.dumps(reply) + '\n').encode())
                        with open(log, 'a') as file:
                            file.write(str(frame.get('cmd')) + '\n')
                    del held[:]
    threading.Thread(target=to_daemon, daemon=True).start()
    threading.Thread(target=refuse, daemon=True).start()
    for line in daemon.makefile('rb'):
        if older:
            line = line.replace(b'"terminal-placement-env-v1",', b'').replace(b',"terminal-placement-env-v1"', b'')
        to_app(line)
    """#

    /// The files of one test: `hold` and `log`, removed by ``remove()``.
    struct Files: Sendable {
        let hold: URL
        let log: URL
        let daemon: Daemon

        init(_ daemon: Daemon) {
            self.daemon = daemon
            let name = "cn-refused-tab-\(UUID().uuidString.prefix(8))"
            hold = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).hold")
            log = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).log")
        }

        /// The bridge that puts the proxy on the daemon's socket.
        var bridge: @Sendable (String) -> DaemonBridge {
            let script = NewTerminalTabRefusedKeysTests.proxy, hold = hold.path, log = log.path, form = daemon.rawValue
            return { path in DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, path, hold, log, form]) }
        }

        /// The commands of the creates the proxy refused so far.
        var refused: [String] {
            (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        }

        func remove() {
            try? FileManager.default.removeItem(at: hold)
            try? FileManager.default.removeItem(at: log)
        }
    }

    /// What each held key saw when it ran again.
    @MainActor final class Replays {
        var state: (@MainActor () -> String)?
        var keys: [String] = []
    }

    private typealias Terminal = (pane: PaneController, tab: String, surface: SurfaceID)

    @Test(arguments: Daemon.allCases)
    func aLineTypedForANewTerminalTabThatTheDaemonRefusesRunsInNoTerminal(_ daemon: Daemon) async throws {
        let files = Files(daemon)
        defer { files.remove() }
        let replays = Replays()
        try await PinnedPageTests.withApp(heldKeyReplay: { event, window, router in
            replays.keys.append(replays.state?() ?? "no state")
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }, bridge: files.bridge) { services, connection in
            let controller = try #require(services.windows.active)
            let content = try #require(controller.workspaceContent)
            let window = try #require(content.layoutView.window)
            let router = services.keyRouter
            let coordinator = router.creationInputCoordinator
            try #require(services.daemon.supports(Self.capability) == (daemon == .current),
                         "the daemon behind the proxy is not the \(daemon.rawValue) form: this run proves nothing")

            // Two confirmed terminal panes (Cmd-D twice; the window's first pane may show an agent chat).
            @MainActor func terminals() -> [Terminal] {
                content.panes.values.compactMap { pane -> Terminal? in
                    guard pane.pane.handle.rawValue < ProvisionalPane.firstHandle, let tab = pane.currentTabKey, case .terminal? = pane.currentContent,
                          let model = pane.pane.tabs.first(where: { $0.id == tab && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) })
                    else { return nil }
                    return (pane, tab, model.surface)
                }
            }
            @MainActor func panes() -> String {
                "panes \(content.panes.values.map { "\($0.pane.handle.rawValue): \($0.pane.tabs.map { "\($0.kind) \($0.surface.rawValue)" })" }), focus \(content.focus.state.resolved)"
            }
            @MainActor func focus(_ terminal: Terminal) async throws {
                PaneHandlers.focus(terminal.pane.layoutPaneID, in: content)
                try await PinnedPageTests.until({
                    content.focus.state.resolved == .terminal(pane: terminal.pane.paneKey, tab: terminal.tab)
                        && (window.firstResponder as? NSView)?.isDescendant(of: terminal.pane.view) == true
                }, report: { "waiting for the focus and the keyboard on \(terminal.tab): \(panes())" })
            }
            var opensTerminal = ActionInvocation(origin: .user)
            opensTerminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: opensTerminal))
            try await PinnedPageTests.until({ terminals().count == 1 }, within: .seconds(30), report: { "waiting for the first split's terminal pane: \(panes())" })
            let other = try #require(terminals().first)
            try await focus(other)
            #expect(services.registry.perform("splitRight", invocation: opensTerminal))
            try await PinnedPageTests.until({ terminals().count == 2 }, within: .seconds(30), report: { "waiting for the second split's terminal pane: \(panes())" })
            let pressed = try #require(terminals().first { $0.pane !== other.pane })
            try await PinnedPageTests.until({ !coordinator.isHolding(in: window) }, report: { "waiting for the splits' creation hold to end" })
            try await focus(pressed)
            let terminalTabs = pressed.pane.pane.tabs.filter { $0.kind == .pty }.count

            // Ctrl-`, as the person presses it; the proxy holds its create.
            try #require(FileManager.default.createFile(atPath: files.hold.path, contents: nil))
            try #require(services.registry.perform("newSurface", invocation: ActionInvocation(origin: .user)), "New Terminal Tab was refused: \(panes())")
            try #require(coordinator.isHolding(in: window), "New Terminal Tab opened no key hold: \(panes())")
            let standIn: String? = daemon == .current ? pressed.pane.stripModel.selectedID?.rawValue : nil
            if daemon == .current {
                let tab = try #require(standIn, "Ctrl-` selected nothing in the pane: \(panes())")
                try #require(ProvisionalTab.isProvisional(tab) && pressed.pane.pane.tabs.contains { $0.id == tab && $0.kind == .pty },
                             "Ctrl-` selected \(tab), not its stand-in terminal: \(panes())")
            }
            try await Task.sleep(for: .milliseconds(300))
            try #require(coordinator.isHolding(in: window) && files.refused.isEmpty, "the proxy did not hold the create: \(panes())")
            if let standIn { try #require(services.daemon.store.creations.isPending(tab: standIn), "the stand-in's create is not pending: \(panes())") }
            replays.state = {
                let keyboard = services.cache.terminals.first { $0.value.session.hasKeyboard(window.firstResponder) }?.key
                let listed = standIn.map { tab in pressed.pane.pane.tabs.contains { $0.id == tab } } ?? false
                let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                return "stand-in listed \(listed), selected \(pressed.pane.stripModel.selectedID?.rawValue ?? "none"), "
                    + "shown \(pressed.pane.currentTabKey ?? "none"), keyboard \(keyboard ?? responder)"
            }

            // The line, typed for the new terminal while its create waits. Its output shows only where a shell ran it.
            let nonce = String(UInt32.random(in: 100_000...999_999))
            let typingTab = controller.focus.currentState().typingTab
            for character in "echo nt\(nonce)x$((6*7))\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                try #require(router.interceptKeyDown(event, in: window), "the creation hold did not take \(text.debugDescription): \(panes())")
            }
            try #require(replays.keys.isEmpty, "a held key ran again before the daemon's answer: \(replays.keys)")

            // The daemon refuses the tab.
            try FileManager.default.removeItem(at: files.hold)
            try await PinnedPageTests.until({ !files.refused.isEmpty && !coordinator.isHolding(in: window) }, within: .seconds(15), report: {
                "waiting for the refusal and the hold's end: refused \(files.refused), holding \(coordinator.isHolding(in: window)), \(panes())"
            })
            if let standIn {
                try await PinnedPageTests.until({ !pressed.pane.pane.tabs.contains { $0.id == standIn } }, within: .seconds(10),
                                                report: { "waiting for the stand-in to leave the pane: \(panes())" })
            }
            let end = coordinator.lastHoldEnd(in: window).map { "\($0)" } ?? "none"
            let how = "the hold ended \(end); refused \(files.refused); typing target at the keys \(typingTab ?? "none"), press-time tab \(pressed.tab), "
                + "stand-in \(standIn ?? "none"); \(replays.keys.count) keys ran again, the first with \(replays.keys.first ?? "-"), the last with \(replays.keys.last ?? "-")"
            print("NewTerminalTabRefusedKeysTests \(daemon.rawValue): \(how)")

            // What the person sees: the line ran in no terminal. The first read waits longer than the 10 s that the daemon
            // keeps keys sent to a terminal it never made (the stand-in's view sends its keys by the terminal's id), so keys
            // that it gives back after that are seen too.
            for (name, terminal, wait) in [("the terminal the person pressed Ctrl-` in", pressed, 15_000), ("the other terminal", other, 3_000)] {
                let reply = try? await connection.request(WaitForTextRequest(surface: terminal.surface, pattern: "nt\(nonce)x42", timeoutMs: wait),
                                                          timeout: .milliseconds(wait + 5_000))
                let ran = reply?.matched == true
                var screen = ""
                if ran { screen = (try? await connection.request(ReadScreenRequest(surface: terminal.surface), timeout: .seconds(5)))?.text ?? "unreadable" }
                #expect(!ran, "\(daemon.rawValue) daemon: the line typed for the refused new terminal tab ran in \(name) (\(how)); its screen: \(screen.debugDescription)")
            }
            #expect(pressed.pane.pane.tabs.filter { $0.kind == .pty }.count == terminalTabs,
                    "the refused create left a terminal tab in the pane: \(panes())")
        }
    }
}
