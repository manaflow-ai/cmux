import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A starting pane for the close tests: a terminal split whose `split` request a proxy on the
/// daemon's socket holds, so the pane shows its stand-in and its view waits for a terminal.
///
/// The proxy holds each `split` while the file `hold` exists and writes the terminal id of each
/// `cancel-creating-input` request the app sends to the file `log`, one id on each line. As an
/// older daemon (``Files/init(olderDaemon:)``) it takes `creating-input-cancel-v1` out of what the
/// daemon says it can do.
@MainActor
struct StartingPaneFixture {
    /// The stand-in pane of the held split.
    let standIn: PaneController
    /// Its one tab.
    let tab: TabModel
    /// The view of that tab, which waits for its terminal.
    let entry: TerminalEntry
    /// The host terminal id the app minted for the split.
    let terminalID: String

    nonisolated static let proxy = #"""
    import json, os, socket, sys, threading, time
    path, hold, log, older = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == 'older'
    daemon = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    daemon.connect(path)
    print('{"ok":true}', file=sys.stderr, flush=True)
    lock, held = threading.Lock(), []
    def to_daemon():
        for line in sys.stdin.buffer:
            try:
                frame = json.loads(line)
            except ValueError:
                frame = {}
            if isinstance(frame, dict) and frame.get('cmd') == 'cancel-creating-input':
                with open(log, 'a') as out:
                    out.write(str(frame.get('terminal_id')) + '\n')
            with lock:
                if isinstance(frame, dict) and frame.get('cmd') == 'split' and os.path.exists(hold):
                    held.append(line)
                    continue
                daemon.sendall(line)
        daemon.shutdown(socket.SHUT_WR)
    def release():
        while True:
            time.sleep(0.02)
            with lock:
                if held and not os.path.exists(hold):
                    for line in held:
                        daemon.sendall(line)
                    del held[:]
    threading.Thread(target=to_daemon, daemon=True).start()
    threading.Thread(target=release, daemon=True).start()
    for line in daemon.makefile('rb'):
        if older:
            line = line.replace(b'"creating-input-cancel-v1",', b'').replace(b',"creating-input-cancel-v1"', b'')
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()
    """#

    /// The files of one test: `hold` and `log`, removed by ``remove()``.
    struct Files: Sendable {
        let hold: URL
        let log: URL
        /// The daemon behind the proxy looks like one from before `creating-input-cancel-v1`.
        let olderDaemon: Bool

        init(olderDaemon: Bool = false) {
            self.olderDaemon = olderDaemon
            let name = "cn-starting-\(UUID().uuidString.prefix(8))"
            hold = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).hold")
            log = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).log")
        }

        /// The bridge that puts the proxy on the daemon's socket.
        var bridge: @Sendable (String) -> DaemonBridge {
            let script = StartingPaneFixture.proxy, hold = hold.path, log = log.path, daemon = olderDaemon ? "older" : "same"
            return { path in DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, path, hold, log, daemon]) }
        }

        /// The terminal ids of the `cancel-creating-input` requests the app sent so far.
        var cancelled: [String] {
            (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        }

        func remove() {
            try? FileManager.default.removeItem(at: hold)
            try? FileManager.default.removeItem(at: log)
        }
    }

    /// Makes a confirmed terminal pane, then a second split that the proxy holds, and types one
    /// key in its stand-in. The pane has the focus when this returns.
    static func start(services: AppServices, content: WorkspaceContentController, window: NSWindow, files: Files) async throws -> StartingPaneFixture {
        _ = try await firstTerminal(services: services, content: content, window: window)
        let before = Set(content.panes.keys)
        try #require(FileManager.default.createFile(atPath: files.hold.path, contents: nil))
        var terminal = ActionInvocation(origin: .user)
        terminal.opensTerminal = true
        #expect(services.registry.perform("splitRight", invocation: terminal), "the split was refused: \(describe(content, services))")
        let standIn = try #require(content.panes.first { !before.contains($0.key) }?.value,
                                   "the split shows no pane in its turn: \(describe(content, services))")
        let tab = try #require(standIn.pane.tabs.first, "the stand-in has no tab")
        try await PinnedPageTests.until({ services.cache.existingTerminal(tab.id) != nil }, report: {
            "waited for the stand-in's terminal view; saw \(describe(content, services))"
        })
        let entry = try #require(services.cache.existingTerminal(tab.id))
        let gate = try #require(entry.gate, "the stand-in's view does not wait for its terminal")
        try await Task.sleep(for: .milliseconds(300))
        try #require(ProvisionalTab.isProvisional(surface: tab.surface) && services.daemon.store.creations.isPending(tab: tab.id) && !gate.isResolved,
                     "the proxy did not hold the split: \(describe(content, services))")
        entry.session.sendBytes(Data("x".utf8))
        let terminalID = try #require(entry.io.creatingTerminalID, "the stand-in's keys have no creating terminal")
        try #require(entry.session.view.window === window, "the stand-in's view is not in the window")
        try #require(!services.cache.terminals.values.contains { $0.session.model.isFocused && $0.gate == nil },
                     "the test needs no focused terminal that could take the keys (a test window is never key)")
        PaneHandlers.focus(standIn.layoutPaneID, in: content)
        return StartingPaneFixture(standIn: standIn, tab: tab, entry: entry, terminalID: terminalID)
    }

    /// A terminal pane split from the test app's first pane, confirmed and focused, with the
    /// window's creation hold ended: the held split starts from a terminal, as a person's does.
    private static func firstTerminal(services: AppServices, content: WorkspaceContentController, window: NSWindow) async throws -> PaneController {
        var terminal = ActionInvocation(origin: .user)
        terminal.opensTerminal = true
        let before = Set(content.panes.keys)
        let coordinator = services.keyRouter.creationInputCoordinator
        #expect(services.registry.perform("splitRight", invocation: terminal), "the first split was refused: \(describe(content, services))")
        @MainActor func made() -> PaneController? {
            content.panes.values.first { pane in
                !before.contains(pane.layoutPaneID) && pane.pane.handle.rawValue < ProvisionalPane.firstHandle
                    && pane.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
            }
        }
        try await PinnedPageTests.until({ made() != nil && !coordinator.isHolding(in: window) }, report: {
            "waited for the first split's confirmed terminal pane and the end of its hold; saw \(describe(content, services))"
        })
        let pane = try #require(made())
        PaneHandlers.focus(pane.layoutPaneID, in: content)
        try await PinnedPageTests.until({
            content.focus.state.pane == pane.paneKey && (window.firstResponder as? NSView)?.isDescendant(of: pane.view) == true
        }, report: { "waited for the focus and the keyboard on the first terminal \(pane.paneKey); saw focus \(content.focus.state.resolved)" })
        return pane
    }

    /// A key-down of `window` through the app's key path: the key router first, then the window
    /// when the router did not take it.
    static func press(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16, services: AppServices, window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: keyCode))
        if !services.keyRouter.interceptKeyDown(event, in: window) { window.sendEvent(event) }
    }

    /// Whether `condition` holds within `timeout`. A timeout is the answer "no", not an error.
    static func eventually(within timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    /// What a failed check saw: each shown pane, the focused pane and the focus on its way.
    static func describe(_ content: WorkspaceContentController, _ services: AppServices) -> String {
        let panes = content.panes.values.map { pane in
            "\(pane.paneKey) h\(pane.pane.handle.rawValue)\(services.daemon.store.pane(pane.pane.handle) == nil ? " (not in the store)" : ""): \(pane.pane.tabs.map { "\($0.kind) \($0.surface.rawValue)" })"
        }
        return "panes \(panes), focus \(content.focus.state.pane ?? "-") \(content.focus.state.resolved), "
            + "expectation \(String(describing: content.focus.state.expectation?.key))"
    }
}
