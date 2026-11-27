import Foundation
import Testing
@testable import CmuxNextDaemon

struct ConversationRunsAnswerLookupTests {
    private struct CapturedCalls: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-run-calls"
    }

    @Test(arguments: [1, 450], [true, false])
    func restoresSilentFollowupBeforeHistoryBoundary(messageCount: Int, supportsAnswers: Bool) async throws {
        let script = #"""
        import json, sys
        count, supported = int(sys.argv[1]), sys.argv[2] == 'true'
        answer = 'question-' + str(count - 1)
        calls = []
        def run(name, started, answers):
            return {'id':name, 'author':'chief', 'status':'done', 'started_at':started, 'answers':answers}
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            command = frame.get('cmd')
            result = {}
            if command == 'identify':
                caps = ['conversation-runs-v1']
                if supported: caps.append('conversation-run-answers-v1')
                result = {'app':'cmux-tui', 'protocol':12, 'generation':'answer-test', 'capabilities':caps}
            elif command == 'conversation-runs':
                calls.append(frame)
                if 'answers' in frame:
                    result = {'runs':[run('silent-followup', 100, [answer])] if answer in frame['answers'] else [], 'has_more':False}
                else:
                    result = {'runs':[run('recent', 250, []), run('boundary', 150, [])], 'has_more':True}
            elif command == 'test-run-calls':
                result = calls
            print(json.dumps({'id':frame.get('id'), 'ok':True, 'data':result}), flush=True)
        """#
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, String(messageCount), String(supportsAnswers)])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-run-answers-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            try await connection.start()
            let ids = (0..<messageCount).map { "question-\($0)" }
            let runs = try await ConversationClient(connection).runs(
                "conversation", oldestStartedAt: 200, turns: [], answers: ids)
            let captured = try await connection.request(CapturedCalls())
            let calls = try #require(captured.arrayValue)
            let lookups = calls.filter { $0["answers"] != nil }
            #expect(lookups.count == (supportsAnswers ? (messageCount + 199) / 200 : 0))
            #expect(calls.count == lookups.count + 1)
            if supportsAnswers {
                let queried = lookups.flatMap { $0["answers"]?.arrayValue ?? [] }
                #expect(queried == ids.map(JSONValue.string))
                #expect(lookups.allSatisfy { ($0["answers"]?.arrayValue?.count ?? 0) <= 200 })
                let report = try #require(runs.first { $0.id == "silent-followup" })
                #expect(report.turn == nil)
                let lastAnswer = try #require(ids.last)
                #expect(report.answers == [lastAnswer])
                #expect(report.startedAt == 100)
            } else {
                #expect(!runs.contains { $0.id == "silent-followup" })
            }
            // History can stop at 150: answer lookups already recovered the older
            // report for the newly assigned question without scanning all runs.
            #expect(calls.last?["before_started_at"] == nil)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}
