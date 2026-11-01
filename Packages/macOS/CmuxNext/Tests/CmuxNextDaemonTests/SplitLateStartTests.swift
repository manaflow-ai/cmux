import Foundation
import Testing
@testable import CmuxNextDaemon

/// cmux NIGHTLY on a loaded Mac (load average ~170, 2026-10-29): a split from the GUI (menu,
/// Cmd-D, the pane header) showed its new pane at once, then snapped back and left no pane. The
/// split's `split` missed the 5 s terminal start deadline, the app took the optimistic pane back
/// (`rejectIntent`), and cmux-tui kept starting the terminal after the app gave up.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport. It serves one request at a
/// time per connection and makes one pane per client-minted `pane_id`, as cmux-tui does
/// (`split-client-keys-v1`: a split sent again with its ids replays the first). It holds the first
/// split's reply past the app's start deadline until the next request arrives (the late start),
/// then answers both in order. The split must wait for the pane and return it, with one pane made.
struct SplitLateStartTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-splits"
    }

    private static let script = #"""
    import json, sys
    mode = sys.argv[1]
    print('{"ok":true}', file=sys.stderr, flush=True)
    splits, panes, held = [], {}, []
    caps = ['terminal-placement-env-v1', 'terminal-env-v1']
    if mode != 'legacy':
        caps.append('split-client-keys-v1')
    def reply(frame, data):
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    def pane(frame):
        key = frame.get('pane_id') or frame.get('terminal_id') or 'unkeyed-%d' % len(splits)
        replayed = key in panes
        if not replayed:
            panes[key] = 10 + len(panes)
        return {'surface': panes[key], 'terminal_id': frame.get('terminal_id'), 'pane_id': frame.get('pane_id'),
                'replayed': replayed}
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'split-late-start-test', 'capabilities': caps})
        elif command in ('split', 'new-pane', 'new-pane-right'):
            splits.append(frame)
            if mode == 'refuse':
                print(json.dumps({'id': frame.get('id'), 'ok': False, 'error': 'unknown pane 3'}), flush=True)
                continue
            if len(splits) == 1:
                held.append(frame)  # the terminal host is still starting on a loaded machine
                continue
            for earlier in held:  # the start ends; this connection's queue drains in order
                reply(earlier, pane(earlier))
            held.clear()
            reply(frame, pane(frame))
        elif command == 'test-splits':
            for earlier in held:
                reply(earlier, pane(earlier))
            held.clear()
            reply(frame, {'splits': splits, 'panes': len(panes)})
        else:
            reply(frame, {})
    """#

    private func connection(_ mode: String) -> DaemonConnection {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, mode])
        return DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-split-late-start-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(1), spawnTimeout: .seconds(1),
                                 terminalEnvironment: nil))
    }

    /// The ids an optimistic split mints for its provisional pane (``ProvisionalPane``).
    private func keyed() -> SpawnOptions {
        var options = SpawnOptions(cwd: "/tmp")
        options.paneID = "pane_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        options.tabID = "tab_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        options.terminalID = TerminalID.generate()
        return options
    }

    @Test(arguments: ["split", "new-pane", "new-pane-right"])
    func aPaneThatStartsLateIsWaitedForAndMadeOnce(_ command: String) async throws {
        let connection = connection("late")
        try await connection.start()
        let options = keyed()
        let created = switch command {
        case "split": try await connection.split(PaneID(rawValue: 3), direction: .right, options: options)
        case "new-pane": try await connection.newPaneInColumn(of: PaneID(rawValue: 3), options: options)
        default: try await connection.newColumn(rightOf: PaneID(rawValue: 3), width: 0.5, options: options)
        }
        let recorded = try await connection.request(Recorded())
        await connection.close()

        let splits = try #require(recorded["splits"]?.arrayValue)
        #expect(splits.count == 2, "the app asks again once the start is late, instead of taking the pane back")
        #expect(splits.allSatisfy { $0["cmd"]?.stringValue == command })
        let panes = splits.map { $0["pane_id"]?.stringValue }
        #expect(panes[0] == options.paneID && panes[1] == options.paneID, "both requests carry the provisional pane's id: \(panes)")
        let terminals = splits.map { $0["terminal_id"]?.stringValue }
        #expect(terminals[0] == options.terminalID?.rawValue && terminals[0] == terminals[1], "both name one terminal: \(terminals)")
        #expect(recorded["panes"]?.doubleValue == 1, "asking again makes no second pane")
        #expect(created.surface == SurfaceID(rawValue: 10), "the split answers the pane the first request started")
        #expect(created.terminalID == options.terminalID)
    }

    @Test func aRefusedSplitIsNotAskedAgain() async throws {
        let connection = connection("refuse")
        try await connection.start()
        await #expect(throws: DaemonError.self) {
            try await connection.split(PaneID(rawValue: 3), direction: .right, options: keyed())
        }
        let recorded = try await connection.request(Recorded())
        await connection.close()
        #expect(try #require(recorded["splits"]?.arrayValue).count == 1, "only a late start is asked again")
    }

    /// A daemon without `split-client-keys-v1` does not replay a split sent again: it would make a
    /// second pane, so the late start still fails there.
    @Test func aDaemonWithoutClientKeysIsNotAskedAgain() async throws {
        let connection = connection("legacy")
        try await connection.start()
        await #expect(throws: DaemonError.self) {
            try await connection.split(PaneID(rawValue: 3), direction: .right, options: keyed())
        }
        let recorded = try await connection.request(Recorded())
        await connection.close()
        #expect(try #require(recorded["splits"]?.arrayValue).count == 1)
    }
}
