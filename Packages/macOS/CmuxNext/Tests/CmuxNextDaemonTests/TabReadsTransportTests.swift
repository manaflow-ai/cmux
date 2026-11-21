import Foundation
import Testing
@testable import CmuxNextDaemon

/// Review of #39311 at 9cedd7c (F1): the connection can come back before the store hears it, while the store still
/// shows the last daemon's tree. An ack names a surface of that tree, so it goes on that tree's transport only
/// (``DaemonConnection/acknowledgeNotifications(of:on:)``); on the new one it fails as not connected and goes again
/// once the new tree says what the surface is.
@Suite(.timeLimit(.minutes(1)))
struct TabReadsTransportTests {
    private struct Acks: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-acks"
    }
    private struct Drop: DaemonRequest {
        typealias Response = EmptyResponse
        static let command = "test-drop"
    }

    @Test func anAckGoesOnlyOnTheTransportWhoseTreeNamedItsSurface() async throws {
        let bridge = DaemonBridge.fakePython(["-c", Self.bridgeScript])
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-tab-reads-\(UUID().uuidString).sock", bridge: bridge),
                                          configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            try await connection.start()
            // The first connection's stamp, then a drop, then the reconnected one's.
            var stamps: [DaemonControlStamp] = []
            for try await event in connection.events {
                guard let stamp = DaemonControlStamp(event) else { continue }
                stamps.append(stamp)
                if stamps.count == 2 { break }
                _ = try await connection.request(Drop())
            }
            let (old, new) = (try #require(stamps.first), try #require(stamps.last))
            #expect(old != new)
            await #expect(throws: DaemonError.notConnected, "an ack named for the last daemon's tree went on the new transport") {
                _ = try await connection.acknowledgeNotifications(of: 1, on: old)
            }
            let reply = try await connection.acknowledgeNotifications(of: 1, on: new)
            #expect(reply.cleared)
            #expect(try await connection.request(Acks()).arrayValue?.count == 1, "the new daemon heard the old tree's ack")
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    private static let bridgeScript = #"""
    import json, sys, uuid
    boot = str(uuid.uuid4())
    acks = []
    def reply(frame, result={}):
        print(json.dumps({'id':frame.get('id'), 'ok':True, 'data':result}), flush=True)
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        cmd = frame.get('cmd')
        if cmd == 'identify':
            reply(frame, {'app':'cmux-tui','protocol':12,'generation':boot,'capabilities':['notification-ack-v1']})
        elif cmd == 'ack-tab-notifications':
            acks.append(frame.get('surface'))
            reply(frame, {'surface':frame.get('surface'),'cleared':True,'acknowledged':[]})
        elif cmd == 'test-acks': reply(frame, acks)
        elif cmd == 'test-drop': reply(frame); break
        else: reply(frame)
    """#
}
