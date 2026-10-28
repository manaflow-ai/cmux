import Foundation
import Testing
@testable import CmuxNextDaemon

/// A daemon accepts the stream but withholds its opening reply. Timeout and cancellation must
/// still cancel that stream on the same live control connection, without waiting for disconnect.
struct ResourceStreamLifecycleTests {
    private struct Opened: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-stream-opened"
    }

    private struct Cancelled: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-stream-cancelled"
    }

    private static let script = #"""
    import json, sys
    print('{"ok":true}', file=sys.stderr, flush=True)
    stream, cancelled, waiting = None, None, []
    def reply(frame, data):
        key = 'result' if frame.get('protocol') else 'data'
        print(json.dumps({'id': frame['id'], 'ok': True, key: data}), flush=True)
    def drain():
        for frame in waiting[:]:
            if frame['cmd'] == 'test-stream-opened' and stream is not None:
                reply(frame, {'stream': stream}); waiting.remove(frame)
            elif frame['cmd'] == 'test-stream-cancelled' and cancelled is not None:
                reply(frame, {'stream': stream, 'cancelled': cancelled}); waiting.remove(frame)
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get('operation') == 'tailnet.state':
            stream = frame['params']['stream_id']
            drain()  # accepted, but the reply to the opening request never arrives
        elif frame.get('operation') == 'stream.cancel':
            cancelled = frame['params']['stream_id']
            reply(frame, {})
            drain()
        elif frame.get('cmd') == 'identify':
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'stream-cleanup-test', 'capabilities': []})
        elif frame.get('cmd') in ('test-stream-opened', 'test-stream-cancelled'):
            waiting.append(frame); drain()
        else:
            reply(frame, {})
    """#

    @Test(arguments: [false, true])
    func anAmbiguousOpenIsCancelledOnItsOwnConnection(cancelTask: Bool) async throws {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-stream-cleanup-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: cancelTask ? nil : .seconds(1), spawnTimeout: .seconds(5),
                                 terminalEnvironment: nil))
        try await connection.start()
        let opening = Task { try await connection.resourceStream(operation: "tailnet.state", params: [:], as: JSONValue.self) }
        _ = try await connection.request(Opened())
        if cancelTask { opening.cancel() }
        // No open-request timeout in the cancellation case: only actual task cancellation can
        // clean up. This independent bounded probe also releases the fixture if cleanup breaks.
        let recorded = try? await connection.request(Cancelled(), timeout: .seconds(3))
        await connection.close()
        do {
            _ = try await opening.value
            Issue.record("the withheld opening reply must not succeed")
        } catch {}
        let result = try #require(recorded, "the accepted stream must be cancelled before connection closure")
        #expect(result["stream"]?.stringValue != nil)
        #expect(result["stream"]?.stringValue == result["cancelled"]?.stringValue)
    }
}
