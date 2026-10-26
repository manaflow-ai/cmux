import Foundation
import Testing
@testable import CmuxNextDaemon

/// Leo, 2026-10-21, on a loaded host: Open Agent Session showed "The terminal did not start: timed
/// out: create-terminal (no reply within 5.0 seconds)", then the terminal appeared late as a bare
/// shell, never attached to the session ("I JUST NEED TH GUI TO ATTACH WHY DOES IT EVEN HAVE A 5
/// SECOND FUCKING TIME OUT"). cmux-tui kept starting the terminal after the app gave up.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport. It serves one request at a
/// time per connection and makes one terminal per mutation id, as cmux-tui does (a keyed
/// `create-terminal` replays). It holds the first reply past the app's terminal start deadline
/// until the next request arrives (the late start), then answers both in order. The create must
/// wait for the terminal and return it, with one terminal made.
struct CreateTerminalLateStartTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-terminal-creates"
    }

    private static let script = #"""
    import json, sys
    mode = sys.argv[1]
    print('{"ok":true}', file=sys.stderr, flush=True)
    creates, terminals, held = [], {}, []
    def reply(frame, data):
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    def terminal(frame):
        key = frame.get('mutation_id') or 'unkeyed-%d' % len(creates)
        replayed = key in terminals
        if not replayed:
            terminals[key] = frame.get('terminal_id') or 'term-%d' % len(terminals)
        return {'surface': 7, 'terminal_id': terminals[key], 'pane': 3, 'screen': 2, 'key': frame.get('key'),
                'lifecycle': 'running', 'replayed': replayed}
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'late-start-test', 'capabilities': []})
        elif command == 'create-terminal':
            creates.append(frame)
            if mode == 'refuse':
                print(json.dumps({'id': frame.get('id'), 'ok': False, 'error': 'no such workspace'}), flush=True)
                continue
            if len(creates) == 1:
                held.append(frame)  # the host is still starting on a loaded machine
                continue
            for earlier in held:  # the start ends; this connection's queue drains in order
                reply(earlier, terminal(earlier))
            held.clear()
            reply(frame, terminal(frame))
        elif command == 'test-terminal-creates':
            reply(frame, {'creates': creates, 'terminals': len(terminals)})
        else:
            reply(frame, {})
    """#

    private func connection(_ mode: String) -> DaemonConnection {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, mode])
        return DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-late-start-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(1), spawnTimeout: .seconds(1),
                                 terminalEnvironment: nil))
    }

    @Test func aTerminalThatStartsLateIsWaitedForAndMadeOnce() async throws {
        let connection = connection("late")
        try await connection.start()
        let key = WorkspaceKey.generate()
        let created = try await connection.createTerminalWaitingForStart(in: key, cwd: "/tmp")
        let recorded = try await connection.request(Recorded())
        await connection.close()

        let creates = try #require(recorded["creates"]?.arrayValue)
        #expect(creates.count == 2, "the app asks again once the start is late, instead of failing")
        let mutations = creates.map { $0["mutation_id"]?.stringValue }
        #expect(mutations[0] != nil && mutations[0] == mutations[1], "both requests carry one mutation id: \(mutations)")
        let terminals = creates.map { $0["terminal_id"]?.stringValue }
        #expect(terminals[0] != nil && terminals[0] == terminals[1], "both requests name one terminal: \(terminals)")
        #expect(recorded["terminals"]?.doubleValue == 1, "asking again makes no second terminal")
        #expect(created.terminalID.rawValue == terminals[0], "the create answers the terminal the first request started")
        // The first request's reply lands after its deadline and is dropped; the answer is the
        // second request's, which cmux-tui serves as a replay of the start that landed late.
        #expect(created.replayed == true, "the answer is the replay of the late start, not a new terminal")
    }

    @Test func aRefusedCreateIsNotAskedAgain() async throws {
        let connection = connection("refuse")
        try await connection.start()
        await #expect(throws: DaemonError.self) {
            try await connection.createTerminalWaitingForStart(in: WorkspaceKey.generate(), cwd: nil)
        }
        let recorded = try await connection.request(Recorded())
        await connection.close()
        let creates = try #require(recorded["creates"]?.arrayValue)
        #expect(creates.count == 1, "only a late start is asked again")
    }
}
