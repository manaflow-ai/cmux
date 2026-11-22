import CmuxNextApps
import CmuxNextDaemon
import Foundation
import Testing

/// The production reader over real request framing, without a user's daemon.
struct AgentInventoryRefreshConnectionTests {
    private struct CapturedRefreshCalls: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-refresh-calls"
    }

    @Test(arguments: ["good", "foreign", "missing", "invalid", "old"])
    func capabilityAndSuccessOwnerAreRequiredWithoutCacheFallback(mode: String) async throws {
        let script = #"""
        import json, sys
        mode, calls = sys.argv[1], []
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            cmd, result = frame.get('cmd'), {}
            if cmd == 'identify':
                result = {'app':'cmux-tui','protocol':12,'generation':'refresh-boot',
                    'capabilities':['agent-inventory-v1','agent-inventory-owner-v1'] if mode == 'old' else ['agent-inventory-refresh-v1']}
            elif cmd in ('agent-inventory', 'agent-inventory-refresh'):
                calls.append(frame)
                result = {'machine':frame['expected_machine_id'],'view':'inventory','cached':True,'harnesses':[]}
                if mode == 'foreign': result['machine'] = 'machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                if mode == 'missing': del result['machine']
                if mode == 'invalid': result['machine'] = 'local'
            elif cmd == 'test-refresh-calls':
                result = calls
            print(json.dumps({'id':frame.get('id'),'ok':True,'data':result}), flush=True)
        """#
        let bridge = DaemonBridge.fakePython(["-c", script, mode])
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-refresh-\(UUID().uuidString).sock", bridge: bridge)
        let connection = DaemonConnection(endpoint: endpoint, configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        let machine: ResourceID = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        do {
            try await connection.start()
            do {
                let value = try await connection.refreshAgentInventory(machine: machine)
                #expect(mode == "good")
                #expect(value.harnesses.isEmpty)
            } catch DaemonError.missingCapabilities(let missing) {
                #expect(mode == "old")
                #expect(missing == ["agent-inventory-refresh-v1"])
            } catch DaemonError.malformedResponse(_) {
                #expect(["foreign", "missing", "invalid"].contains(mode))
            }
            let captured = try await connection.request(CapturedRefreshCalls())
            let calls = try #require(captured.arrayValue)
            #expect(calls.count == (mode == "old" ? 0 : 1))
            for call in calls {
                #expect(call["cmd"] == .string("agent-inventory-refresh"))
                #expect(call["expected_machine_id"] == .string(machine.rawValue))
                guard case .object(let fields) = call else { Issue.record("refresh request object"); continue }
                #expect(Set(fields.keys) == ["id", "cmd", "expected_machine_id"])
            }
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}
