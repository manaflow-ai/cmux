import Foundation
import Testing
@testable import CmuxNextDaemon

/// Reply before spawn on the app side (p05-ipc-131, F10): a caller that follows the start asks a
/// daemon with `terminal-async-start-v1` to answer `new-tab` or `split` once it admitted the terminal
/// (`async_start`); only that request keeps the control deadline instead of the terminal start
/// deadline, and the start's own outcome (`terminal-started`, `terminal-start-failed`) reaches it
/// through a ``TerminalStartWatch`` opened before the request went out. Every other request is sent
/// and timed as before.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport (python3 through a
/// ``DaemonBridge``), one request at a time.
struct TerminalStartWatchTests {
    private struct Release: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "test-release-start"
    }

    /// argv[1]: `async` (advertises the capability) or `sync`; argv[2]: what the release emits
    /// (`started`, `failed`, `others-then-failed`: 100 other terminals' starts first) or `hold`
    /// (new-tab's reply waits 1.5 s). A `sync` daemon refuses `async_start`; an `async` one answers
    /// `starting: true` only when asked.
    private static let script = #"""
    import json, sys, time
    mode, outcome = sys.argv[1], sys.argv[2]
    print('{"ok":true}', file=sys.stderr, flush=True)
    caps = ['terminal-placement-env-v1'] + (['terminal-async-start-v1'] if mode == 'async' else [])
    pending = []
    def reply(frame, data):
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    def refuse(frame, error):
        print(json.dumps({'id': frame.get('id'), 'ok': False, 'error': error}), flush=True)
    def event(name, **fields):
        fields['event'] = name
        print(json.dumps(fields), flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'async-start-test', 'capabilities': caps})
        elif command == 'new-tab':
            asked = frame.get('async_start') is True
            if asked and mode == 'sync':
                refuse(frame, 'unknown parameter async_start')
                continue
            terminal = frame.get('terminal_id')
            if outcome == 'hold':
                time.sleep(1.5)  # a host that takes this long to start, and a reply that waits for it
            pending.append(terminal)
            data = {'surface': 7, 'terminal_id': terminal}
            if asked:
                data['starting'] = True
            reply(frame, data)
        elif command == 'test-release-start':
            for terminal in pending:
                if outcome == 'started':
                    event('terminal-started', terminal_id=terminal)
                elif outcome == 'failed':
                    event('terminal-start-failed', terminal_id=terminal, error='exec failed')
                elif outcome == 'others-then-failed':
                    for other in range(100):
                        event('terminal-started', terminal_id='%032x' % (other + 1))
                    event('terminal-start-failed', terminal_id=terminal, error='exec failed')
            pending.clear()
            reply(frame, {})
        else:
            reply(frame, {})
    """#

    private func connection(_ mode: String, _ outcome: String) -> DaemonConnection {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, mode, outcome])
        return DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-async-start-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(1), spawnTimeout: .seconds(10),
                                 terminalEnvironment: nil))
    }

    private static func options(_ terminal: TerminalID, asyncStart: Bool) -> SpawnOptions {
        var options = SpawnOptions()
        options.terminalID = terminal
        options.asyncStart = asyncStart ? true : nil
        return options
    }

    // MARK: The ask and the deadline

    @Test func aDaemonThatAnswersAfterTheStartKeepsTheTerminalStartDeadline() async throws {
        let connection = connection("sync", "hold")
        try await connection.start()
        connection.discardEvents()
        let created = try await connection.newTab(in: PaneID(rawValue: 3), options: Self.options(.generate(), asyncStart: true))
        await connection.close()
        #expect(created.surface == SurfaceID(rawValue: 7), "a 1.5 s start is inside the 10 s terminal start deadline, and the ask was dropped")
        #expect(created.starting == nil)
    }

    @Test func aRequestThatDoesNotAskKeepsTheTerminalStartDeadlineOnACapableDaemon() async throws {
        let connection = connection("async", "hold")
        try await connection.start()
        connection.discardEvents()
        let created = try await connection.newTab(in: PaneID(rawValue: 3), options: Self.options(.generate(), asyncStart: false))
        await connection.close()
        #expect(created.surface == SurfaceID(rawValue: 7), "a caller that does not follow the start waits for it as before")
        #expect(created.starting == nil, "no admit-time reply for a caller that does not watch the start")
    }

    @Test func aRequestThatAsksGetsTheControlDeadline() async throws {
        let connection = connection("async", "hold")
        try await connection.start()
        connection.discardEvents()
        do {
            _ = try await connection.newTab(in: PaneID(rawValue: 3), options: Self.options(.generate(), asyncStart: true))
            Issue.record("a 1.5 s reply passed the 1 s control deadline")
        } catch DaemonError.timedOut {
            // The control deadline: a reply that never comes is a lost request, not a late terminal.
        } catch {
            Issue.record("expected the control deadline's timedOut, got \(error)")
        }
        await connection.close()
    }

    @Test func onlyARequestThatAsksLeavesTheTerminalStartDeadline() {
        let configuration = DaemonConnectionConfiguration(requestTimeout: .seconds(2), spawnTimeout: .seconds(5), terminalEnvironment: nil)
        let async = DaemonIdentity(capabilities: [DaemonCapability.terminalAsyncStart.rawValue], generation: "g")
        let sync = DaemonIdentity(capabilities: [], generation: "g")
        var asking = SpawnOptions()
        asking.asyncStart = true
        #expect(NewTabRequest(pane: nil, options: asking).asksAsyncStart)
        #expect(SplitRequest(pane: PaneID(rawValue: 3), direction: .right, options: asking).asksAsyncStart)
        #expect(!NewTabRequest(pane: nil).asksAsyncStart && !SplitRequest(pane: PaneID(rawValue: 3), direction: .right).asksAsyncStart)
        #expect(!NewTabRequest(pane: nil, options: asking).withoutAsyncStart().asksAsyncStart)
        #expect(!CreateTerminalRequest(workspace: .key(.generate()), mutation: nil).asksAsyncStart)
        #expect(!NewPaneRequest(pane: PaneID(rawValue: 3), options: asking).asksAsyncStart, "new-pane has no admit-time reply")

        let atAdmit = RequestDeadline.forSpawning(true, on: async, configuration: configuration)
        #expect(atAdmit.timeout == .seconds(2) && !atAdmit.waitsForTerminalStart)
        let notAsked = RequestDeadline.forSpawning(false, on: async, configuration: configuration)
        #expect(notAsked.timeout == .seconds(5) && notAsked.waitsForTerminalStart)
        let olderDaemon = RequestDeadline.forSpawning(true, on: sync, configuration: configuration)
        #expect(olderDaemon.timeout == .seconds(5) && olderDaemon.waitsForTerminalStart)
    }

    // MARK: The watch

    @Test func theWatchEndsOnItsOwnTerminalsFailurePastOtherTerminalsEvents() async throws {
        let connection = connection("async", "others-then-failed")
        try await connection.start()
        connection.discardEvents()
        let terminal = TerminalID.generate()
        let watch = TerminalStartWatch(terminal, on: connection)
        let created = try await connection.newTab(in: PaneID(rawValue: 3), options: Self.options(terminal, asyncStart: true))
        #expect(created.starting == true)
        _ = try await connection.request(Release())
        // Read only now: 100 other terminals' starts came first, past the inbox's limit.
        let ended = await watch.outcome()
        await connection.close()
        #expect(ended == .failed(TerminalStartFailure(terminal: terminal, reason: "exec failed")),
                "other terminals' starts never reach this watch, so they cannot overflow it")
    }

    @Test func theWatchEndsOnItsTerminalsStart() async throws {
        let connection = connection("async", "started")
        try await connection.start()
        connection.discardEvents()
        let terminal = TerminalID.generate()
        let watch = TerminalStartWatch(terminal, on: connection)
        _ = try await connection.newTab(in: PaneID(rawValue: 3), options: Self.options(terminal, asyncStart: true))
        let outcome = Task { await watch.outcome() }
        _ = try await connection.request(Release())
        let ended = await outcome.value
        await connection.close()
        #expect(ended == .started)
    }

    @Test func aClosedConnectionLeavesTheOutcomeToTheNextSnapshot() async throws {
        let connection = connection("async", "started")
        try await connection.start()
        connection.discardEvents()
        let terminal = TerminalID.generate()
        let watch = TerminalStartWatch(terminal, on: connection)
        _ = try await connection.newTab(in: PaneID(rawValue: 3), options: Self.options(terminal, asyncStart: true))
        await connection.close()
        #expect(await watch.outcome() == .unknown)
    }

    @Test func aStartWithNoOutcomeEndsAtTheStartDeadline() async {
        let route = DaemonEventRoute()
        let watch = TerminalStartWatch(terminal: .generate(), subscription: route.subscribe(filter: .all, limit: 4),
                                       bound: .milliseconds(50), clock: ContinuousClock())
        #expect(await watch.outcome() == .unknown, "a start the daemon never reports does not hold its follow-up")
    }

    @Test func onlyItsTerminalsEventsReachTheWatch() {
        let terminal = TerminalID.generate()
        let other = TerminalID.generate()
        func concerns(_ event: DaemonEvent) -> Bool { TerminalStartWatch.concerns(event, terminal: terminal) }
        func payload(_ id: String) -> JSONValue { .object(["terminal_id": .string(id)]) }
        #expect(concerns(.unknown(name: "terminal-started", payload: payload(terminal.rawValue))))
        #expect(concerns(.unknown(name: "terminal-start-failed", payload: payload(terminal.rawValue.uppercased()))))
        #expect(!concerns(.unknown(name: "terminal-started", payload: payload(other.rawValue))))
        #expect(!concerns(.unknown(name: "terminal-registry-changed", payload: payload(terminal.rawValue))))

        let mine = TabSnapshot(surface: SurfaceID(rawValue: 7), terminalID: terminal, kind: .pty)
        let theirs = TabSnapshot(surface: SurfaceID(rawValue: 8), terminalID: other, kind: .pty)
        func tabClosed(_ tab: TabSnapshot) -> DaemonEvent {
            .tabClosed(TabDelta(workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: PaneID(rawValue: 3),
                                surface: tab.surface, index: nil, entity: tab, clientTransactionID: nil))
        }
        func paneClosed(_ tabs: [TabSnapshot]) -> DaemonEvent {
            .paneClosed(PaneDelta(workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: PaneID(rawValue: 3),
                                  index: nil, entity: PaneSnapshot(id: PaneID(rawValue: 3), tabs: tabs), clientTransactionID: nil))
        }
        func workspaceClosed(_ tabs: [TabSnapshot]) -> DaemonEvent {
            let pane = PaneSnapshot(id: PaneID(rawValue: 3), tabs: tabs)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: 2), layout: .leaf(PaneID(rawValue: 3)), panes: [pane])
            let workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "1", screens: [screen])
            return .workspaceClosed(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 1), index: nil, entity: workspace, workspaceRevision: 2))
        }
        #expect(concerns(tabClosed(mine)) && !concerns(tabClosed(theirs)))
        #expect(concerns(paneClosed([theirs, mine])) && !concerns(paneClosed([theirs])))
        #expect(concerns(workspaceClosed([mine])) && !concerns(workspaceClosed([theirs])))
        #expect(concerns(.disconnected(reason: "lost")))
        #expect(!concerns(.treeChanged(transaction: nil)) && !concerns(.bell(surface: SurfaceID(rawValue: 7))))

        func outcome(_ event: DaemonEvent) -> TerminalStartOutcome? { TerminalStartWatch.outcome(of: event, terminal: terminal) }
        #expect(outcome(.unknown(name: "terminal-started", payload: payload(terminal.rawValue))) == .started)
        #expect(outcome(.unknown(name: "terminal-start-failed", payload: .object(["terminal_id": .string(terminal.rawValue),
                                                                                  "error": .string("exec failed")])))
            == .failed(TerminalStartFailure(terminal: terminal, reason: "exec failed")))
        #expect(outcome(tabClosed(mine)) == .closed && outcome(paneClosed([mine])) == .closed && outcome(workspaceClosed([mine])) == .closed)
        #expect(outcome(.disconnected(reason: "lost")) == .unknown)
    }
}
