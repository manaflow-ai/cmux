import Foundation
import Testing
@testable import CmuxNextDaemon

/// Reply before spawn on the app side (p05-ipc-131, F10): a daemon with `terminal-async-start-v1`
/// answers `new-tab`, `split` and `create-terminal` once it admitted the terminal, so those requests
/// keep the control deadline instead of the terminal start deadline, and the start's own outcome
/// (`terminal-started`, `terminal-start-failed`) reaches the command through a ``TerminalStartWatch``
/// opened before the request went out.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport (python3 through a
/// ``DaemonBridge``), one request at a time.
struct TerminalStartWatchTests {
    private struct Release: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "test-release-start"
    }

    /// argv[1]: `async` (advertises the capability) or `sync`; argv[2]: what the release emits
    /// (`started`, `failed`, `other-then-failed`) or `hold` (new-tab's reply waits 1.5 s).
    private static let script = #"""
    import json, sys, time
    mode, outcome = sys.argv[1], sys.argv[2]
    print('{"ok":true}', file=sys.stderr, flush=True)
    caps = ['terminal-placement-env-v1'] + (['terminal-async-start-v1'] if mode == 'async' else [])
    pending = []
    def reply(frame, data):
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    def event(name, **fields):
        fields['event'] = name
        print(json.dumps(fields), flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'async-start-test', 'capabilities': caps})
        elif command == 'new-tab':
            terminal = frame.get('terminal_id')
            if outcome == 'hold':
                time.sleep(1.5)  # a host that takes this long to start, on a daemon that answers after it
            pending.append(terminal)
            data = {'surface': 7, 'terminal_id': terminal}
            if mode == 'async':
                data['starting'] = True
            reply(frame, data)
        elif command == 'test-release-start':
            for terminal in pending:
                if outcome == 'started':
                    event('terminal-started', terminal_id=terminal)
                elif outcome == 'failed':
                    event('terminal-start-failed', terminal_id=terminal, error='exec failed')
                elif outcome == 'other-then-failed':
                    event('terminal-started', terminal_id='someone-else')
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

    private static func options(_ terminal: TerminalID) -> SpawnOptions {
        var options = SpawnOptions()
        options.terminalID = terminal
        return options
    }

    // MARK: The deadline

    @Test func aDaemonThatAnswersAfterTheStartKeepsTheTerminalStartDeadline() async throws {
        let connection = connection("sync", "hold")
        try await connection.start()
        connection.discardEvents()
        let created = try await connection.newTab(in: PaneID(rawValue: 3), options: Self.options(.generate()))
        await connection.close()
        #expect(created.surface == SurfaceID(rawValue: 7), "a 1.5 s start is inside the 10 s terminal start deadline")
        #expect(created.starting == nil)
    }

    @Test func aDaemonThatAnswersAtAdmitGetsTheControlDeadline() async throws {
        let connection = connection("async", "hold")
        try await connection.start()
        connection.discardEvents()
        do {
            _ = try await connection.newTab(in: PaneID(rawValue: 3), options: Self.options(.generate()))
            Issue.record("a 1.5 s reply passed the 1 s control deadline")
        } catch DaemonError.timedOut {
            // The control deadline: a reply that never comes is a lost request, not a late terminal.
        } catch {
            Issue.record("expected the control deadline's timedOut, got \(error)")
        }
        await connection.close()
    }

    @Test func onlyCommandsThatAnswerAtAdmitLeaveTheTerminalStartDeadline() {
        let configuration = DaemonConnectionConfiguration(requestTimeout: .seconds(2), spawnTimeout: .seconds(5), terminalEnvironment: nil)
        let async = DaemonIdentity(capabilities: [DaemonCapability.terminalAsyncStart.rawValue], generation: "g")
        let sync = DaemonIdentity(capabilities: [], generation: "g")
        #expect(NewTabRequest.repliesBeforeTerminalStart && SplitRequest.repliesBeforeTerminalStart
            && CreateTerminalRequest.repliesBeforeTerminalStart)
        #expect(!NewPaneRequest.repliesBeforeTerminalStart && !NewColumnRequest.repliesBeforeTerminalStart)

        let atAdmit = RequestDeadline.forSpawning(true, on: async, configuration: configuration)
        #expect(atAdmit.timeout == .seconds(2) && !atAdmit.waitsForTerminalStart)
        let afterStart = RequestDeadline.forSpawning(false, on: async, configuration: configuration)
        #expect(afterStart.timeout == .seconds(5) && afterStart.waitsForTerminalStart)
        let olderDaemon = RequestDeadline.forSpawning(true, on: sync, configuration: configuration)
        #expect(olderDaemon.timeout == .seconds(5) && olderDaemon.waitsForTerminalStart)
    }

    // MARK: The watch

    @Test func theWatchEndsOnItsOwnTerminalsFailure() async throws {
        let connection = connection("async", "other-then-failed")
        try await connection.start()
        connection.discardEvents()
        let terminal = TerminalID.generate()
        let watch = TerminalStartWatch(terminal, on: connection)
        let created = try await connection.newTab(in: PaneID(rawValue: 3), options: Self.options(terminal))
        #expect(created.starting == true)
        let outcome = Task { await watch.outcome(of: created) }
        _ = try await connection.request(Release())
        let ended = await outcome.value
        await connection.close()
        #expect(ended == .failed(TerminalStartFailure(terminal: terminal, reason: "exec failed")),
                "another terminal's start is not this one's")
    }

    @Test func theWatchEndsOnItsTerminalsStart() async throws {
        let connection = connection("async", "started")
        try await connection.start()
        connection.discardEvents()
        let terminal = TerminalID.generate()
        let watch = TerminalStartWatch(terminal, on: connection)
        let created = try await connection.newTab(in: PaneID(rawValue: 3), options: Self.options(terminal))
        let outcome = Task { await watch.outcome(of: created) }
        _ = try await connection.request(Release())
        let ended = await outcome.value
        await connection.close()
        #expect(ended == .started)
    }

    @Test func aReplyWithoutStartingHasStarted() async {
        let route = DaemonEventRoute()
        let watch = TerminalStartWatch(terminal: .generate(), subscription: route.subscribe(filter: .all, limit: 4))
        #expect(await watch.outcome(of: SurfaceCreated(surface: SurfaceID(rawValue: 7))) == .started)
    }

    @Test func aClosedConnectionLeavesTheOutcomeToTheNextSnapshot() async throws {
        let connection = connection("async", "started")
        try await connection.start()
        connection.discardEvents()
        let terminal = TerminalID.generate()
        let watch = TerminalStartWatch(terminal, on: connection)
        let created = try await connection.newTab(in: PaneID(rawValue: 3), options: Self.options(terminal))
        await connection.close()
        #expect(await watch.outcome(of: created) == .unknown)
    }

    @Test func onlyItsTerminalAndItsTabEndTheStart() {
        let terminal = TerminalID.generate(), surface = SurfaceID(rawValue: 7)
        func outcome(_ event: DaemonEvent) -> TerminalStartOutcome? {
            TerminalStartWatch.outcome(of: event, terminal: terminal, surface: surface)
        }
        let started: JSONValue = .object(["event": .string("terminal-started"), "terminal_id": .string(terminal.rawValue)])
        let other: JSONValue = .object(["event": .string("terminal-started"), "terminal_id": .string("other")])
        let failed: JSONValue = .object(["event": .string("terminal-start-failed"), "terminal_id": .string(terminal.rawValue)])
        #expect(outcome(.unknown(name: "terminal-started", payload: started)) == .started)
        #expect(outcome(.unknown(name: "terminal-started", payload: other)) == nil)
        #expect(outcome(.unknown(name: "terminal-start-failed", payload: failed)) == .failed(TerminalStartFailure(terminal: terminal, reason: nil)))
        #expect(outcome(.unknown(name: "terminal-registry-changed", payload: started)) == nil)
        let tab = TabSnapshot(surface: surface, terminalID: terminal, kind: .pty)
        func closed(_ surface: SurfaceID) -> DaemonEvent {
            .tabClosed(TabDelta(workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: PaneID(rawValue: 3),
                                surface: surface, index: nil, entity: tab, clientTransactionID: nil))
        }
        #expect(outcome(closed(surface)) == .closed)
        #expect(outcome(closed(SurfaceID(rawValue: 8))) == nil)
        #expect(outcome(.disconnected(reason: "lost")) == .unknown)
        #expect(TerminalStartWatch.mayEnd(.unknown(name: "terminal-start-failed", payload: failed)))
        #expect(!TerminalStartWatch.mayEnd(.bell(surface: surface)))
    }
}
