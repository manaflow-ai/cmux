import Foundation
import Testing
@testable import CmuxNextDaemon

/// A tree snapshot cannot acknowledge session state that only the event stream carries.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct SnapshotSessionBarrierTests {
    private struct AwaitAgents: DaemonRequest {
        typealias Response = EmptyResponse
        static let command = "test-await-agents"
    }

    private struct ReleaseAgents: DaemonRequest {
        typealias Response = EmptyResponse
        static let command = "test-release-agents"
    }

    @Test func snapshotDoesNotAcknowledgeAHeldSidebarBatch() async throws {
        let bridge = DaemonBridge.fakePython(["-c", Self.script])
        let connection = DaemonConnection(
            endpoint: DaemonEndpoint(socketPath: "/tmp/cmux-snapshot-barrier-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], terminalEnvironment: nil, sessionEvents: true))
        let store = DaemonStore()
        let (batches, continuation) = AsyncStream<SidebarDocBatch>.makeStream()
        var received = false
        store.session.onSidebarBatch = { batch in
            received = true
            continuation.yield(batch)
            continuation.finish()
        }
        let running = Task { await store.run(connection: connection) }
        do {
            try await connection.start()
            // This reply is held until resync has applied its snapshot and asked for agents.
            // The agents reply stays withheld, so resync cannot drain its held inbox yet.
            _ = try await connection.request(AwaitAgents())
            let barrier = try #require(await connection.eventSequence())
            #expect(store.isLoaded)
            #expect(received || store.appliedSequence < barrier,
                    "the snapshot acknowledged a sidebar batch that its tree does not contain")

            _ = try await connection.request(ReleaseAgents())
            var iterator = batches.makeAsyncIterator()
            let batch = try #require(await iterator.next())
            #expect(batch.idempotencyKey == "snapshot-barrier-test")
            #expect(await store.appliedThrough(barrier, since: store.connectionEpoch))
            await connection.closeAndWait()
            await running.value
        } catch {
            await connection.closeAndWait()
            await running.value
            throw error
        }
    }

    private static let script = #"""
    import json, sys
    stream = None
    snapshot = None
    agents = None
    awaiting = []
    print('{"ok":true}', file=sys.stderr, flush=True)

    def answer(frame, value, resource=False):
        print(json.dumps({'id':frame['id'], 'ok':True,
                          'result' if resource else 'data':value}), flush=True)

    def snapshot_when_subscribed():
        global snapshot
        if stream is None or snapshot is None:
            return
        # Transport order makes this batch part of the snapshot reply's event barrier,
        # but list-workspaces contains none of its sidebar document state.
        print(json.dumps({'type':'stream_item', 'stream_id':stream, 'item':{
            'kind':'delta', 'revision':'1', 'idempotency_key':'snapshot-barrier-test',
            'changes':[{'kind':'state_upsert', 'resource':'sidebar_doc', 'id':'sidebar_doc',
                        'value':{'revision':'1', 'previous_revision':'0',
                                 'idempotency_key':'snapshot-barrier-test'}}]}}), flush=True)
        answer(snapshot, {'workspaces':[]})
        snapshot = None

    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            answer(frame, {'app':'cmux-tui', 'protocol':12, 'generation':'barrier-test',
                           'session':'barrier-test', 'capabilities':['state-resources-v1']})
        elif frame.get('operation') == 'session.events':
            stream = frame['params']['stream_id']
            answer(frame, {'stream_id':stream}, resource=True)
            snapshot_when_subscribed()
        elif command == 'list-workspaces':
            snapshot = frame
            snapshot_when_subscribed()
        elif command == 'list-agents':
            agents = frame
            for waiter in awaiting:
                answer(waiter, {})
            awaiting = []
        elif command == 'test-await-agents':
            if agents is None:
                awaiting.append(frame)
            else:
                answer(frame, {})
        elif command == 'test-release-agents':
            answer(agents, {'agents':[]})
            agents = None
            answer(frame, {})
        else:
            answer(frame, {})
    """#
}
