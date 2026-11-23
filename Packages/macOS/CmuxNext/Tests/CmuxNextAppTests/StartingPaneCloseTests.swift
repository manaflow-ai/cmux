import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextFocusUI
import CmuxNextTerminal
import Foundation
import Testing

/// A split whose daemon does not answer: the new pane shows at once (its stand-in), its terminal
/// says `starting`, and the person can close it four ways: Close Tab's shortcut with the focus in
/// it, the close button of its tab, Close in its label, and Close Pane with the focus in it. All
/// four give the same result (cmux-shared-behavior): the creation is cancelled, the view's wait for its terminal ends, the
/// keys typed in it reach no other terminal, and when the daemon answers at last, exactly ONE close
/// is sent for the pane it made, which never shows.
///
/// The app runs on a same-tree cmux-tui through a proxy on its socket that holds each `split`
/// request while a file exists: the daemon is silent for the split and answers everything else.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct StartingPaneCloseTests {
    /// The ways to close the pane.
    nonisolated enum Way: String, CaseIterable, Sendable {
        case closeTabShortcut, tabCloseButton, labelClose, closePaneAction
    }

    /// The surfaces a close was sent for (written and read on the main actor only).
    private nonisolated final class Closes: @unchecked Sendable {
        var surfaces: [SurfaceID] = []
    }

    /// How the view's wait for its terminal ended: nil while it waits, then whether it got one.
    private nonisolated final class GateWait: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?
        var gotTerminal: Bool? { lock.withLock { result } }
        func ended(with terminal: Bool) { lock.withLock { result = terminal } }
    }

    static let proxy = #"""
    import json, os, socket, sys, threading, time
    path, hold = sys.argv[1], sys.argv[2]
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
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()
    """#

    private static func bridge(hold: String) -> @Sendable (String) -> DaemonBridge {
        let script = proxy
        return { path in DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, path, hold]) }
    }

    @Test(arguments: Way.allCases)
    func closeOfAStartingPaneCancelsItSendsOneCloseAndDropsItsKeys(way: Way) async throws {
        let hold = FileManager.default.temporaryDirectory.appendingPathComponent("cn-starting-hold-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: hold) }
        try await PinnedPageTests.withApp(bridge: Self.bridge(hold: hold.path)) { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            let windowID = try #require(services.windows.owner(of: window)?.state.id)
            let store = services.daemon.store
            let coordinator = services.keyRouter.creationInputCoordinator
            let original = try await Self.startingTerminal(services: services, content: content, window: window)
            let before = Set(content.panes.keys)

            // The daemon goes silent for the next split.
            try #require(FileManager.default.createFile(atPath: hold.path, contents: nil))
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: terminal), "the split was refused: \(Self.describe(content, services))")
            let standIn = try #require(content.panes.first { !before.contains($0.key) }?.value,
                                       "the split shows no pane in its turn: \(Self.describe(content, services))")
            let tab = try #require(standIn.pane.tabs.first, "the stand-in has no tab")
            try await PinnedPageTests.until({ services.cache.existingTerminal(tab.id) != nil }, report: {
                "waited for the stand-in's terminal view; saw \(Self.describe(content, services))"
            })
            let entry = try #require(services.cache.existingTerminal(tab.id))
            let gate = try #require(entry.gate, "the stand-in's view does not wait for its terminal")
            let view = entry.session.view
            try await Task.sleep(for: .milliseconds(300))
            try #require(ProvisionalTab.isProvisional(surface: tab.surface) && store.creations.isPending(tab: tab.id) && !gate.isResolved,
                         "the proxy did not hold the split: \(Self.describe(content, services))")
            let transaction = try #require(CancelledCreation.transaction(showingTab: tab.id, in: store))

            // The pane says that it starts (its label shows the mark after 1 s, the words after 10 s).
            let starting = await Self.eventually(within: .seconds(5)) { entry.session.model.connection == .starting }
            #expect(starting, "the pane of a split the daemon has not answered says \(entry.session.model.connection)")

            // Keys typed in it. The daemon gives them back while the pane still has the focus (as
            // it does 10 s after the first): no terminal can take them yet, so they are held.
            entry.session.sendBytes(Data("x".utf8))
            let terminalID = try #require(entry.io.creatingTerminalID, "the stand-in's keys have no creating terminal")
            try #require(view.window === window, "the stand-in's view is not in the window")
            try #require(!services.cache.terminals.values.contains { $0.session.model.isFocused && $0.gate == nil },
                         "the test needs no focused terminal that could take the keys (a test window is never key)")
            coordinator.giveBack(Data("echo typed-in-the-starting-pane\r".utf8), terminal: terminalID)

            // Close, one of the ways.
            switch way {
            case .closeTabShortcut:
                PaneHandlers.focus(standIn.layoutPaneID, in: content)
                try #require(content.focus.state.pane == standIn.paneKey && content.focus.state.expectation == nil,
                             "the test needs the focus on the starting pane: \(Self.describe(content, services))")
                _ = try Self.press("w", .command, keyCode: 13, services: services, window: window)
            case .tabCloseButton:
                standIn.handle(.close(StripTabID(tab.id), source: .mouse))
            case .labelClose:
                let close = try #require(view.onCloseStarting, "the label of the starting pane has no Close")
                close()
            case .closePaneAction:
                // Close Pane after the split's focus arrived (the state at 10 s): the pane is the focused one.
                PaneHandlers.focus(standIn.layoutPaneID, in: content)
                try #require(content.focus.state.pane == standIn.paneKey && content.focus.state.expectation == nil,
                             "the test needs the focus on the starting pane: \(Self.describe(content, services))")
                #expect(services.registry.perform("closePane", invocation: ActionInvocation(origin: .user)), "Close Pane was refused")
            }

            // In the close's turn: the creation is cancelled.
            #expect(!store.creations.isPending(tab: tab.id),
                    "\(way.rawValue) did not cancel the split (last key run \(String(describing: services.keyRouter.lastInterception))): \(Self.describe(content, services))")

            // The keys it gave back reach no terminal of the window: not those held, not those the
            // daemon gives back after the close.
            var given = Data()
            GivenBackInput.shared.deliver(window: windowID, to: { given.append($0) })
            #expect(given.isEmpty, "keys typed in the closed pane went to another terminal: \(String(decoding: given, as: UTF8.self))")
            coordinator.giveBack(Data("echo given-back-after-the-close\r".utf8), terminal: terminalID)
            GivenBackInput.shared.deliver(window: windowID, to: { given.append($0) })
            #expect(given.isEmpty, "keys given back after the close went to another terminal: \(String(decoding: given, as: UTF8.self))")

            // The starting pane leaves the window, and its view's wait for a terminal ends with none.
            let gone = await Self.eventually { !content.panes.values.contains { $0.paneKey == standIn.paneKey } }
            #expect(gone, "\(way.rawValue) left the starting pane: \(Self.describe(content, services))")
            let wait = GateWait()
            let waiter = Task { let target = await gate.value(); wait.ended(with: target != nil) }
            let ended = await Self.eventually(within: .seconds(10)) { wait.gotTerminal != nil }
            #expect(ended, "the closed pane's view still waits for a terminal")
            #expect(wait.gotTerminal != true && !gate.isResolved, "the closed pane's view got a terminal")
            if ended { await waiter.value }

            // The daemon answers at last: exactly one close goes out, for the pane of this split.
            let closes = Closes()
            let send = try #require(store.intentLog.closeCancelled, "\(way.rawValue) did not arm the close of the cancelled split")
            store.intentLog.closeCancelled = { closed, surface in
                if closed == transaction { closes.surfaces.append(surface) }
                send(closed, surface)
            }
            try FileManager.default.removeItem(at: hold)
            let closed = await Self.eventually { closes.surfaces.count >= 1 && Set(content.panes.keys) == before }
            #expect(closed, "after the daemon answered: closes \(closes.surfaces.count), \(Self.describe(content, services))")
            try await Task.sleep(for: .milliseconds(700))
            #expect(closes.surfaces.count == 1, "the closed split got \(closes.surfaces.count) closes")
            #expect(Set(content.panes.keys) == before, "the closed split's pane shows: \(Self.describe(content, services))")
            #expect(content.panes.values.contains { $0 === original }, "the first terminal's pane is gone: \(Self.describe(content, services))")
        }
    }

    /// A terminal pane split from the test app's first pane (an agent chat), confirmed and focused,
    /// with the window's creation hold ended: the silent split starts from a terminal, as a person's does.
    private static func startingTerminal(services: AppServices, content: WorkspaceContentController, window: NSWindow) async throws -> PaneController {
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
    /// when the router did not take it. Returns whether the key router took it.
    private static func press(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16, services: AppServices,
                              window: NSWindow) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: keyCode))
        let taken = services.keyRouter.interceptKeyDown(event, in: window)
        if !taken { window.sendEvent(event) }
        return taken
    }

    /// Whether `condition` holds within `timeout`. A timeout is the answer "no", not an error.
    private static func eventually(within timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    /// What a failed check saw: each shown pane (its key, handle, whether the store has it, its tabs), the focused pane.
    private static func describe(_ content: WorkspaceContentController, _ services: AppServices) -> String {
        let panes = content.panes.values.map { pane in
            "\(pane.paneKey) h\(pane.pane.handle.rawValue)\(services.daemon.store.pane(pane.pane.handle) == nil ? " (not in the store)" : ""): \(pane.pane.tabs.map { "\($0.kind) \($0.surface.rawValue)" })"
        }
        return "panes \(panes), focus \(content.focus.state.pane ?? "-") \(content.focus.state.resolved), "
            + "expectation \(String(describing: content.focus.state.expectation?.key))"
    }
}
