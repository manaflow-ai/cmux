import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// #32408: in a 512-workspace classic upgrade the store kept a new workspace with no screens. The
/// daemon writes its events from one thread and a reply from another, so an event emitted after
/// `list-workspaces` read the tree can reach the socket before that reply. The snapshot barrier was
/// the count of events read before the reply, so the store took that event as part of the snapshot
/// and skipped it: the screen it added was in neither.
///
/// The barrier comes from the daemon's own order: the reply names how many lines the connection had
/// written when the command read the tree (`lines_written_before_read`); an event written after
/// that line is past the barrier and applies.
@Suite(.timeLimit(.minutes(1))) struct SnapshotReadBarrierTests {
    /// Serves the handshake. On `list-workspaces` it writes, as the daemon can, a `screen-added`
    /// emitted after its tree read and before its reply; the tree has the workspace with no screens.
    private static let script = #"""
    import json, sys
    print('{"ok":true}', file=sys.stderr, flush=True)  # the bridge's dial answer
    written = 0
    def say(value):
        global written
        print(json.dumps(value), flush=True)
        written += 1
    for line in sys.stdin:
        frame = json.loads(line)
        cmd = frame.get('cmd')
        if cmd == 'identify':
            say({'id': frame.get('id'), 'ok': True,
                 'data': {'app': 'cmux-tui', 'protocol': 12, 'generation': 'read-barrier-test', 'capabilities': []}})
        elif cmd == 'list-workspaces':
            read_at = written
            say({'event': 'screen-added', 'workspace': 1, 'screen': 2, 'index': 0, 'entity': {'id': 2, 'active': True}})
            say({'id': frame.get('id'), 'ok': True,
                 'data': {'workspace_revision': 1, 'lines_written_before_read': read_at,
                          'workspaces': [{'id': 1, 'key': 'w1', 'name': 'one', 'screens': []}]}})
        else:
            say({'id': frame.get('id'), 'ok': True, 'data': {}})
    """#

    @MainActor @Test func aScreenAddedAfterTheTreeReadIsNotLost() async throws {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-read-barrier-\(UUID().uuidString.prefix(8)).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(5), spawnTimeout: .seconds(5),
                                 terminalEnvironment: nil))
        _ = try await connection.start()
        let (tree, barrier) = try await connection.snapshot()
        var events = connection.events.makeAsyncIterator()
        var added: DaemonEventEnvelope?
        while added == nil, let envelope = try await events.next() {
            if case .screenAdded = envelope.event { added = envelope }
        }
        let screenAdded = try #require(added)
        #expect(screenAdded.sequence > barrier,
                "the screen added after the tree read was taken as part of the snapshot (barrier \(barrier), event \(screenAdded.sequence))")

        let store = DaemonStore()
        store.apply(snapshot: tree)
        store.snapshotBarrier = barrier
        store.apply(batch: [screenAdded])
        #expect(store.workspace(id: "w1")?.screens.count == 1, "the store lost the screen: it is in neither the snapshot nor an applied event")
        await connection.close()
    }
}
