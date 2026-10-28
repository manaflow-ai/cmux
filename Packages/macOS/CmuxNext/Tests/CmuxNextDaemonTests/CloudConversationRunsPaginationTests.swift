import Foundation
import Testing
@testable import CmuxNextDaemon

struct CloudConversationRunsPaginationTests {
    private struct CapturedPages: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-run-pages"
    }

    /// Exercise the production client, capability handshake, and wire cursor through
    /// the same fixture bridge used by AgentInventoryWatchConnectionTests.
    @Test(arguments: ["resolved", "late-reply", "manual-reply", "stalled-cursor"])
    func readsUntilLoadedRepliesResolveOrHistoryEnds(mode: String) async throws {
        let script = #"""
        import json, sys
        mode = sys.argv[1]
        calls = []
        def run(name, started, turn):
            return {'id':name, 'author':'chief', 'turn':turn, 'status':'done', 'started_at':started}
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            command = frame.get('cmd')
            result = {}
            if command == 'identify':
                result = {'app':'cmux-tui', 'protocol':12, 'generation':'run-page-test',
                          'capabilities':['cloud-conversations-v1', 'cloud-conversation-runs-v1']}
            elif command == 'cloud-conversation-runs':
                calls.append(frame)
                if len(calls) == 1:
                    result = {'runs':[run('recent', 250, 'recent-reply'), run('boundary', 150, None)], 'has_more':True}
                elif len(calls) == 2:
                    result = {'runs':[run('long-running', 100, 'late-reply')], 'has_more':True}
                    if mode == 'stalled-cursor':
                        result = {'runs':[run('boundary', 150, None)], 'has_more':True}
                else:
                    result = {'runs':[], 'has_more':False}
            elif command == 'test-run-pages':
                result = calls
            print(json.dumps({'id':frame.get('id'), 'ok':True, 'data':result}), flush=True)
        """#
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, mode])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-run-pages-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            try await connection.start()
            let expectedTurns: Set<String> = mode == "resolved" ? ["recent-reply"]
                : mode == "manual-reply" ? ["manual-reply"] : ["recent-reply", "late-reply"]
            let runs = try await CloudConversationClient(connection).runs(
                "conversation", agent: "chief", oldestStartedAt: 200, expectedTurns: expectedTurns)
            let captured = try await connection.request(CapturedPages())
            let calls = try #require(captured.arrayValue)
            let expectedCount = mode == "resolved" ? 1 : mode == "manual-reply" ? 3 : 2
            #expect(calls.count == expectedCount)
            #expect(calls.first?["before_started_at"] == nil)
            for call in calls {
                #expect(call["conversation"] == .string("conversation"))
                #expect(call["agent"] == .string("chief"))
                #expect(call["limit"] == .number(100))
            }
            if calls.count > 1 { #expect(calls[1]["before_started_at"] == .number(150)) }
            if calls.count > 2 { #expect(calls[2]["before_started_at"] == .number(100)) }
            if mode == "late-reply" || mode == "manual-reply" {
                // The loaded reply's run started before the transcript's oldest message.
                #expect(runs.contains { $0.id == "long-running" && $0.turn == "late-reply" })
            } else if mode == "resolved" {
                #expect(runs.map(\.id) == ["recent", "boundary"])
            }
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}
