import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// CREATION HOLD NO-LANE KEYS. The person presses Ctrl-` (New Terminal Tab) in a terminal and types a line with Return
/// for the new terminal. The window's creation hold keeps the line until the daemon answers the create. When the daemon
/// refuses the tab, the new terminal never exists, and the line must run in no terminal. The hold's ticket had no lane
/// (no tab), so each of its keys ended as "run again as typed" in what has the keyboard: after the stand-in went away
/// that was the terminal the person pressed Ctrl-` in, and its shell ran a line typed for another terminal.
///
/// The app runs on a same-tree cmux-tui through a proxy that holds the tab's create while a file exists and then answers
/// it `ok:false` itself, or sends it on to the daemon when a second file says so (the good path). As an older daemon the
/// proxy also takes `terminal-placement-env-v1` out of what the daemon says it can do: New Terminal Tab then shows no
/// stand-in and waits for the create (`create-terminal`, then a move).
///
/// The proxy can also hold the daemon's events (`tab-added` with them) from the moment it sends the create on, while
/// the create's reply passes: the reply then comes before the events, for a time the test chooses (``Late``). For one
/// case it also holds the stream lines of the control connection and the reply itself, until the test saw that the
/// store applied each line that the daemon sent before: the reply then settles the create at once.
///
/// Three cases, each on both daemon forms:
/// - the daemon refuses the tab: the line runs in no terminal;
/// - the daemon makes the tab: the line runs in the made terminal, in the typed order, and in no other terminal;
/// - the person moves to another pane after Ctrl-` and types there, and the daemon refuses the tab: the line is that
///   pane's terminal's, as with no create. Only keys typed while the create is the person's newest intent are the new
///   terminal's.
///
/// And on the current form, for each ``Late``: the person types the start of a line for the new terminal, moves to
/// another pane, the daemon makes the tab, and the person types the rest in the made terminal. The hold keeps the held
/// keys until the store lists the made terminal's tab (the store's change wakes it) and gives them to that terminal;
/// the stand-in goes away when the daemon's tab comes, or at the reply when the reply settles the create. The made
/// terminal must get each key, in the typed order, the held ones before the later ones.
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
    passes, late, quiet = hold + '.pass', hold + '.late', hold + '.quiet'
    daemon = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    daemon.connect(path)
    print('{"ok":true}', file=sys.stderr, flush=True)
    lock, out, held = threading.Lock(), threading.Lock(), []
    events, parked, wait = threading.Lock(), [], {'on': False, 'ids': [], 'at': None, 'quiet': False, 'reply': None}
    def to_app(line):
        with out:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
    def delay():
        try:
            with open(late) as file:
                text = file.read().strip()
        except OSError:
            return None
        return float(text) if text else None
    def release():
        with events:
            if wait['reply'] is not None and not os.path.exists(quiet):
                to_app(wait['reply'])
                wait['reply'] = None
                with open(log, 'a') as file:
                    file.write('replied\n')
            due = wait['at'] is not None and time.time() >= wait['at']
            if wait['on'] and wait['reply'] is None and (due or (wait['at'] is None and not os.path.exists(late))):
                for line in parked:
                    to_app(line)
                del parked[:]
                wait['on'] = False
                with open(log, 'a') as file:
                    file.write('events released\n')
    def to_daemon():
        for line in sys.stdin.buffer:
            try:
                frame = json.loads(line)
            except ValueError:
                frame = {}
            with lock:
                if isinstance(frame, dict) and frame.get('cmd') in ('new-tab', 'create-terminal') and os.path.exists(hold):
                    held.append((frame, line))
                    continue
                daemon.sendall(line)
        daemon.shutdown(socket.SHUT_WR)
    def answer():
        while True:
            time.sleep(0.02)
            with lock:
                if held and not os.path.exists(hold):
                    made = os.path.exists(passes)
                    for frame, line in held:
                        if made:
                            if os.path.exists(late):
                                with events:
                                    wait['on'] = True
                                    wait['ids'].append(frame.get('id'))
                                    wait['quiet'] = os.path.exists(quiet)
                            daemon.sendall(line)
                        else:
                            reply = {'id': frame.get('id'), 'ok': False, 'error': 'refused by the proxy of the test'}
                            to_app((json.dumps(reply) + '\n').encode())
                        with open(log, 'a') as file:
                            file.write(('passed ' if made else 'refused ') + str(frame.get('cmd')) + '\n')
                    del held[:]
            release()
    threading.Thread(target=to_daemon, daemon=True).start()
    threading.Thread(target=answer, daemon=True).start()
    for line in daemon.makefile('rb'):
        if older:
            line = line.replace(b'"terminal-placement-env-v1",', b'').replace(b',"terminal-placement-env-v1"', b'')
        with events:
            if wait['on']:
                try:
                    frame = json.loads(line)
                except ValueError:
                    frame = {}
                streamed = wait['quiet'] and isinstance(frame, dict) and frame.get('type') in ('stream_item', 'stream_end')
                if streamed or (isinstance(frame, dict) and 'event' in frame):
                    parked.append(line)
                    continue
                if wait['quiet'] and isinstance(frame, dict) and frame.get('id') in wait['ids']:
                    wait['reply'] = line
                    with open(log, 'a') as file:
                        file.write('reply held\n')
                    continue
                if isinstance(frame, dict) and frame.get('id') in wait['ids'] and wait['at'] is None:
                    after = delay()
                    if after is not None:
                        wait['at'] = time.time() + after / 1000.0
                    with open(log, 'a') as file:
                        file.write('replied\n')
            to_app(line)
    """#

    /// The files of one test: `hold`, `pass` (the proxy sends a held create on to the daemon), `late` (the proxy holds the
    /// daemon's events from then on: until the file is removed, or for the milliseconds it names after the create's reply),
    /// `quiet` (with `late`: the proxy holds the stream lines too, and the create's reply until the file is removed)
    /// and `log`, removed by ``remove()``.
    struct Files: Sendable {
        let hold: URL
        let pass: URL
        let late: URL
        let quiet: URL
        let log: URL
        let daemon: Daemon

        init(_ daemon: Daemon) {
            self.daemon = daemon
            let name = "cn-refused-tab-\(UUID().uuidString.prefix(8))"
            hold = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).hold")
            pass = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).hold.pass")
            late = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).hold.late")
            quiet = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).hold.quiet")
            log = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).log")
        }

        /// The bridge that puts the proxy on the daemon's socket.
        var bridge: @Sendable (String) -> DaemonBridge {
            let script = NewTerminalTabRefusedKeysTests.proxy, hold = hold.path, log = log.path, form = daemon.rawValue
            return { path in DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, path, hold, log, form]) }
        }

        /// The creates the proxy answered so far: `refused <cmd>` or `passed <cmd>`.
        var answered: [String] { logged.filter { $0.hasPrefix("refused ") || $0.hasPrefix("passed ") } }

        /// Each line of the proxy's log: the answers, `reply held` (the proxy keeps a create's reply), `replied` (a
        /// create's reply passed while the events wait) and `events released`.
        var logged: [String] {
            (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        }

        func remove() {
            try? FileManager.default.removeItem(at: hold)
            try? FileManager.default.removeItem(at: pass)
            try? FileManager.default.removeItem(at: late)
            try? FileManager.default.removeItem(at: quiet)
            try? FileManager.default.removeItem(at: log)
        }
    }

    /// What each held key saw when it ran again.
    @MainActor final class Replays {
        var state: (@MainActor () -> String)?
        var keys: [String] = []
    }

    private typealias Terminal = (pane: PaneController, tab: String, surface: SurfaceID)

    /// How the create ends, and what the person did before they typed.
    nonisolated enum Ending: Sendable {
        /// The daemon refuses the tab.
        case refused
        /// The daemon makes the tab.
        case made
        /// The person moves to the other pane after Ctrl-`, types there, and the daemon refuses the tab.
        case movedThenRefused
        /// The person types the start of a line, moves to the other pane, the daemon makes the tab, and the person
        /// types the rest of the line in the made terminal.
        case madeAfterAMove
    }

    /// When the daemon's events (`tab-added` with them) reach the app, against the reply of the create.
    nonisolated enum Late: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// As the daemon sends them.
        case asSent
        /// From 10 to 30 ms after the reply (the proxy looks each 20 ms): the stand-in goes away while its view may
        /// still send the held keys.
        case soonAfterTheReply
        /// After the app handled the reply, while the hold waits for the made terminal's tab: the test lets the events
        /// go only when it saw the hold still holding with no made tab in the store. The hold then ends by the tab's
        /// listing. (Before the hold waited for the tab this case was `afterTheHoldsEnd`: the hold ended at the reply
        /// and the held keys had only the stand-in to go to.)
        case whileTheHoldWaitsForTheTab
        /// As ``whileTheHoldWaitsForTheTab``, and the create's reply reaches the app only after the store applied each
        /// line that the daemon sent before it (the proxy holds the stream lines and the reply too). The reply then
        /// settles the create in its own turn (`DaemonStore.noteSettled`): the stand-in leaves the pane before the hold
        /// gives its keys out, with no made tab in the store. The cases before this one do not force that order: a
        /// stream line that passes the proxy, or a line not applied yet, keeps the create pending at the reply.
        case afterTheStoreAppliedEachLine

        /// The test lets the daemon's events go only after it saw the hold wait for the made terminal's tab.
        var holdWaitsForTheTab: Bool { self == .whileTheHoldWaitsForTheTab || self == .afterTheStoreAppliedEachLine }
        var testDescription: String { rawValue }
    }

    @Test(arguments: Daemon.allCases)
    func aLineTypedForANewTerminalTabThatTheDaemonRefusesRunsInNoTerminal(_ daemon: Daemon) async throws {
        try await Self.run(daemon, .refused)
    }

    /// The good path: the keys typed while the create waits reach the terminal the daemon made, in the typed order.
    @Test(arguments: Daemon.allCases)
    func aLineTypedForANewTerminalTabRunsInTheTerminalTheDaemonMade(_ daemon: Daemon) async throws {
        try await Self.run(daemon, .made)
    }

    /// The create is the new terminal's claim on the keys only while it is the person's newest intent in the window:
    /// a move of the person to another pane ends it, and what they type then is that pane's terminal's.
    @Test(arguments: Daemon.allCases)
    func aLineTypedAfterThePersonMovedToAnotherPaneRunsThereWhenTheDaemonRefusesTheNewTerminalTab(_ daemon: Daemon) async throws {
        try await Self.run(daemon, .movedThenRefused)
    }

    /// The hold keeps a made terminal's held keys until the store lists its tab, and gives them to that terminal then.
    /// A key sent into a stand-in that is gone (the reply settled the create), or a key that comes after one typed later,
    /// is a typing fault: the made terminal's shell must get the whole line in the typed order. In the two cases where
    /// the test holds the events back, the hold must still hold after the reply (it waits for the tab) and must end by
    /// the tab's listing, not by its limit: the test reads the end's reason, never a time.
    @Test(arguments: Late.allCases)
    func theKeysHeldForAMadeTerminalReachItInOrderBeforeALaterKeyAfterThePersonMovedAway(_ events: Late) async throws {
        try await Self.run(.current, .madeAfterAMove, events: events)
    }

    private static func run(_ daemon: Daemon, _ ending: Ending, events: Late = .asSent) async throws {
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
            let before = Set(pressed.pane.pane.tabs.map(\.surface))
            // The cases that hold the events back until the hold waits for the tab: a long limit of the hold (the test's
            // value, through the coordinator's own `holdLimit`), so the hold can end only by the tab's listing.
            let waitsForTheTab = ending == .madeAfterAMove && events.holdWaitsForTheTab
            if waitsForTheTab { coordinator.holdLimit = .seconds(120) }

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
            try #require(coordinator.isHolding(in: window) && files.answered.isEmpty, "the proxy did not hold the create: \(panes())")
            if let standIn { try #require(services.daemon.store.creations.isPending(tab: standIn), "the stand-in's create is not pending: \(panes())") }
            replays.state = {
                let keyboard = services.cache.terminals.first { $0.value.session.hasKeyboard(window.firstResponder) }?.key
                let listed = standIn.map { tab in pressed.pane.pane.tabs.contains { $0.id == tab } } ?? false
                let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                return "stand-in listed \(listed), selected \(pressed.pane.stripModel.selectedID?.rawValue ?? "none"), "
                    + "shown \(pressed.pane.currentTabKey ?? "none"), keyboard \(keyboard ?? responder)"
            }

            // The person moves to the other pane (their newer intent) before they type.
            if ending == .movedThenRefused {
                try await focus(other)
                try #require(coordinator.isHolding(in: window) && files.answered.isEmpty, "the hold ended at the person's move: \(panes())")
            }

            // The line, typed while the create waits. Its output shows only where a shell ran it, and only when each
            // key came in the typed order.
            let nonce = String(UInt32.random(in: 100_000...999_999))
            // The moved-away case, typed in two parts (held, then later): a lost key changes the sum or breaks the line,
            // and the line that the terminal shows gives the order of the keys.
            let heldPart = "echo nt\(nonce)x$((12345*6789+1011-", laterPart = "1213-1415))\r"
            let answer = ending == .madeAfterAMove ? "\(12_345 * 6_789 + 1_011 - 1_213 - 1_415)" : "42"
            @MainActor func ran(in surface: SurfaceID, within wait: Int) async -> (ran: Bool, screen: String) {
                let reply = try? await connection.request(WaitForTextRequest(surface: surface, pattern: "nt\(nonce)x\(answer)", timeoutMs: wait),
                                                          timeout: .milliseconds(wait + 5_000))
                let screen = (try? await connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(5)))?.text ?? "unreadable"
                return (reply?.matched == true, screen)
            }
            let typingTab = controller.focus.currentState().typingTab
            /// Types `line` as the person does. `held`: the creation hold must take each key; else a key that no hold
            /// takes goes on to the window's first responder.
            @MainActor func typeLine(_ line: String, held: Bool) throws {
                for character in line {
                    let text = String(character)
                    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                              context: nil, characters: text, charactersIgnoringModifiers: text,
                                                              isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                    if held {
                        try #require(router.interceptKeyDown(event, in: window), "the creation hold did not take \(text.debugDescription): \(panes())")
                    } else if !router.interceptKeyDown(event, in: window) {
                        window.sendEvent(event)
                    }
                }
            }
            try typeLine(ending == .madeAfterAMove ? heldPart : "echo nt\(nonce)x$((6*7))\r", held: true)
            try #require(replays.keys.isEmpty, "a held key ran again before the daemon's answer: \(replays.keys)")
            // The person moves to the other pane with the start of the line held for the new terminal.
            if ending == .madeAfterAMove {
                try await focus(other)
                try #require(coordinator.isHolding(in: window) && files.answered.isEmpty && replays.keys.isEmpty,
                             "the hold ended at the person's move: \(replays.keys.count) keys ran again, \(panes())")
            }

            // The daemon's answer: it refuses the tab, or (the proxy sends the create on) makes it.
            let makes = ending == .made || ending == .madeAfterAMove
            if makes { try #require(FileManager.default.createFile(atPath: files.pass.path, contents: nil)) }
            if ending == .madeAfterAMove, events != .asSent {
                try #require(FileManager.default.createFile(atPath: files.late.path, contents: events == .soonAfterTheReply ? Data("10".utf8) : nil))
            }
            let store = services.daemon.store
            let link = try #require(services.daemon.connection, "the app has no connection to the daemon")
            if ending == .madeAfterAMove, events == .afterTheStoreAppliedEachLine {
                try #require(FileManager.default.createFile(atPath: files.quiet.path, contents: nil))
            }
            let answeredAt = ContinuousClock.now
            try FileManager.default.removeItem(at: files.hold)
            var atTheReply = "not asked"
            if ending == .madeAfterAMove, events == .afterTheStoreAppliedEachLine {
                // The proxy keeps the reply and each event and stream line after the create. The store applies what the
                // daemon sent before: then the reply's event sequence is one that the store reached, and the reply
                // settles the create at once.
                try await PinnedPageTests.until({ files.logged.contains("reply held") }, within: .seconds(15), report: { "waiting for the proxy to hold the create's reply: \(files.logged)" })
                var routed = await link.eventSequence()
                let deadline = ContinuousClock.now + .seconds(10)
                while routed.map({ store.appliedSequence < $0 }) ?? true, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                    routed = await link.eventSequence()
                }
                let reached = try #require(routed, "the connection has no event sequence: this run proves nothing")
                try #require(store.appliedSequence >= reached && coordinator.isHolding(in: window) && (standIn.map { tab in pressed.pane.pane.tabs.contains { $0.id == tab } } ?? false),
                             "before the reply: the store applied \(store.appliedSequence) of the routed \(reached), holding \(coordinator.isHolding(in: window)): this run proves nothing (\(panes()))")
                atTheReply = "applied \(store.appliedSequence) of the routed \(reached)"
                try FileManager.default.removeItem(at: files.quiet)
            }
            @MainActor func madeTerminal() -> SurfaceID? {
                pressed.pane.pane.tabs.first { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) && !before.contains($0.surface) }?.surface
            }
            var heldForTheTab = "not asked"
            if waitsForTheTab {
                // The app handled the reply: no creation of the hold waits any more. The flush that the reply asked for
                // runs in a main-actor turn of its own, queued before this task's next turns.
                try await PinnedPageTests.until({ !files.answered.isEmpty && files.logged.contains("replied") && !coordinator.hasPendingCreation(in: window) }, within: .seconds(15), report: {
                    "waiting for the app to handle the create's reply: answered \(files.answered), proxy log \(files.logged), \(panes())"
                })
                for _ in 0..<8 { await Task.yield() }
                try #require(madeTerminal() == nil && !files.logged.contains("events released"),
                             "the daemon's events came before the test let them go: this run proves nothing (proxy log \(files.logged), \(panes()))")
                // The gate under test: the store lists no made tab, so the hold keeps the keys. The reply can settle the
                // create before `tab-added` comes, and the stand-in then leaves the pane at the reply: where the stand-in
                // was then is printed, and required only in the case that forces that order.
                let held = coordinator.isHolding(in: window)
                let listed = standIn.map { tab in pressed.pane.pane.tabs.contains { $0.id == tab } } ?? false
                let viewKept = standIn.map { services.cache.existingTerminal($0) != nil } ?? false
                let routed = await link.eventSequence().map { "\($0)" } ?? "none"
                heldForTheTab = "the reply was handled \(ContinuousClock.now - answeredAt) after the answer; the hold held then \(held) with no made tab in the store, "
                    + "\(replays.keys.count) keys ran again by then, the stand-in listed then \(listed), its view kept then \(viewKept), "
                    + "the store applied \(store.appliedSequence) of the routed \(routed) then, before the reply: \(atTheReply)"
                #expect(held, "the hold gave its keys out at the reply, with no made tab in the store: it did not wait for the tab (\(heldForTheTab); proxy log \(files.logged))")
                if events == .afterTheStoreAppliedEachLine {
                    try #require(!listed, "the stand-in was in the pane after the reply: the reply did not settle the create, and this run proves nothing (\(heldForTheTab); proxy log \(files.logged))")
                }
                try FileManager.default.removeItem(at: files.late)
            }
            try await PinnedPageTests.until({ !files.answered.isEmpty && !coordinator.isHolding(in: window) }, within: .seconds(15), report: {
                "waiting for the answer and the hold's end: answered \(files.answered), holding \(coordinator.isHolding(in: window)), \(panes())"
            })
            try #require(files.answered.allSatisfy { $0.hasPrefix(makes ? "passed " : "refused ") }, "the proxy answered \(files.answered): this run proves nothing")
            if waitsForTheTab {
                // The hold ended by the store's listing of the made tab (the limit of this run's hold is 120 s; the 15 s
                // above only stop a run whose hold never ends). The end's reason is read, not a time.
                let reason = coordinator.lastHoldEnd(in: window).map { "\($0)" } ?? "none"
                heldForTheTab += "; the hold ended \(reason) with the made tab listed \(madeTerminal() != nil)"
                #expect(reason == "focusLanded" && madeTerminal() != nil,
                        "the hold did not end by the listing of the made terminal's tab (\(heldForTheTab); proxy log \(files.logged))")
            }
            if ending == .madeAfterAMove, events == .soonAfterTheReply {
                try await PinnedPageTests.until({ files.logged.contains("events released") }, within: .seconds(10), report: { "waiting for the proxy to release the events: \(files.logged)" })
            }
            if let standIn {
                try await PinnedPageTests.until({ !pressed.pane.pane.tabs.contains { $0.id == standIn } }, within: .seconds(10),
                                                report: { "waiting for the stand-in to leave the pane: \(panes())" })
            }
            let end = coordinator.lastHoldEnd(in: window).map { "\($0)" } ?? "none"
            let how = "the hold ended \(end); answered \(files.answered); typing target at the keys \(typingTab ?? "none"), press-time tab \(pressed.tab), "
                + "stand-in \(standIn ?? "none"); \(replays.keys.count) keys ran again, the first with \(replays.keys.first ?? "-"), the last with \(replays.keys.last ?? "-")"
            print("NewTerminalTabRefusedKeysTests \(daemon.rawValue) \(ending): \(how)")
            let pressTerminal = "the terminal the person pressed Ctrl-` in"

            switch ending {
            case .refused:
                // What the person sees: the line ran in no terminal. The first read waits longer than the 10 s that the
                // daemon keeps keys sent to a terminal it never made (the stand-in's view sends its keys by the terminal's
                // id), so keys that it gives back after that are seen too.
                for (name, terminal, wait) in [(pressTerminal, pressed, 15_000), ("the other terminal", other, 3_000)] {
                    let result = await ran(in: terminal.surface, within: wait)
                    #expect(!result.ran, "\(daemon.rawValue) daemon: the line typed for the refused new terminal tab ran in \(name) (\(how)); its screen: \(result.screen.debugDescription)")
                }
                #expect(pressed.pane.pane.tabs.filter { $0.kind == .pty }.count == terminalTabs,
                        "the refused create left a terminal tab in the pane: \(panes())")
            case .made:
                // The made terminal's shell ran the line: each key reached it, in the typed order. No other shell ran it.
                try await PinnedPageTests.until({ madeTerminal() != nil }, within: .seconds(15), report: { "waiting for the made terminal's tab in the pane: \(panes())" })
                let made = try #require(madeTerminal())
                let result = await ran(in: made, within: 15_000)
                #expect(result.ran, "\(daemon.rawValue) daemon: the line typed for the new terminal tab did not run in the terminal the daemon made (\(how)); its screen: \(result.screen.debugDescription)")
                for (name, terminal) in [(pressTerminal, pressed), ("the other terminal", other)] {
                    let result = await ran(in: terminal.surface, within: 3_000)
                    #expect(!result.ran, "\(daemon.rawValue) daemon: the line typed for the new terminal tab ran in \(name) (\(how)); its screen: \(result.screen.debugDescription)")
                }
            case .madeAfterAMove:
                // The person goes to the made terminal and types the rest of the line there.
                try await PinnedPageTests.until({ madeTerminal() != nil }, within: .seconds(15), report: { "waiting for the made terminal's tab in the pane: \(panes()), proxy log \(files.logged)" })
                let made = try #require(madeTerminal())
                let madeTab = try #require(pressed.pane.pane.tabs.first { $0.surface == made }?.id)
                let listedAt = ContinuousClock.now
                if pressed.pane.currentTabKey != madeTab { pressed.pane.select(TabID(madeTab)) }
                try await focus((pressed.pane, madeTab, made))
                let laterKeyAfter = ContinuousClock.now - listedAt
                try typeLine(laterPart, held: false)
                let timing = "events \(events.rawValue); the hold waited for the tab: \(heldForTheTab); the first later key \(laterKeyAfter) after the made tab was listed; proxy log \(files.logged)"
                print("NewTerminalTabRefusedKeysTests madeAfterAMove \(events.rawValue): \(timing)")
                // The shell printed the sum only if it got each key of both parts, the held ones first and in the typed order.
                let result = await ran(in: made, within: 15_000)
                #expect(result.ran, "the made terminal did not get the line as typed: a held key was lost or came out of order (\(timing); \(how)); its screen: \(result.screen.debugDescription)")
                // Its screen shows the keys in the order they came: the whole typed line (a narrow pane wraps it).
                let typed = String((heldPart + laterPart).dropLast())
                #expect(result.screen.filter { !$0.isWhitespace }.contains(typed.filter { !$0.isWhitespace }),
                        "the made terminal's screen does not show the typed line \(typed.debugDescription) (\(timing)); its screen: \(result.screen.debugDescription)")
                for (name, terminal) in [(pressTerminal, pressed), ("the other terminal", other)] {
                    let screen = (try? await connection.request(ReadScreenRequest(surface: terminal.surface), timeout: .seconds(5)))?.text ?? "unreadable"
                    #expect(!screen.contains("nt\(nonce)"), "a key typed for the new terminal reached \(name) (\(timing); \(how)); its screen: \(screen.debugDescription)")
                }
            case .movedThenRefused:
                // The line is the terminal's that the person moved to: it ran there, and not in the terminal of the press.
                let there = await ran(in: other.surface, within: 15_000)
                #expect(there.ran, "\(daemon.rawValue) daemon: the line typed after the person moved to another pane did not run in that pane's terminal (\(how)); its screen: \(there.screen.debugDescription)")
                let result = await ran(in: pressed.surface, within: 3_000)
                #expect(!result.ran, "\(daemon.rawValue) daemon: the line typed after the person moved to another pane ran in \(pressTerminal) (\(how)); its screen: \(result.screen.debugDescription)")
                #expect(pressed.pane.pane.tabs.filter { $0.kind == .pty }.count == terminalTabs,
                        "the refused create left a terminal tab in the pane: \(panes())")
            }
        }
    }
}
