import Foundation
import Testing
@testable import CmuxNextDaemon

/// Real connection capability admission and request framing over a bounded
/// fixture bridge; no user daemon, account or CLI is started.
struct AgentInventoryWatchConnectionTests {
    private struct CapturedWatchCalls: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-watch-calls"
    }

    @Test(arguments: [false, true])
    func theReadyConnectionNegotiatesBothDirectionsWithoutLegacyFallback(modern: Bool) async throws {
        let script = #"""
        import json, sys
        modern = sys.argv[1] == 'yes'
        calls = []
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            cmd = frame.get('cmd')
            result = {}
            if cmd == 'identify':
                result = {'app':'cmux-tui','protocol':12,'generation':'watch-boot',
                    'capabilities':['agent-inventory-watch-v1'] if modern else ['agent-inventory-v1']}
            elif cmd == 'agent-inventory-watch':
                calls.append(frame)
                if frame.get('enabled') is True:
                    result = {'machine':frame['expected_machine_id'],
                        'watch_id':'inventory_watch_0123456789abcdef0123456789abcdef',
                        'revision':18446744073709551615}
            elif cmd == 'test-watch-calls':
                result = calls
            print(json.dumps({'id':frame.get('id'),'ok':True,'data':result}), flush=True)
        """#
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, modern ? "yes" : "no"])
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-watch-test-\(UUID().uuidString).sock", bridge: bridge)
        let connection = DaemonConnection(endpoint: endpoint, configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        let machine: ResourceID = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        do {
            try await connection.start()
            do {
                let receipt = try await connection.request(MachineAgentInventoryWatchRequest(expectedMachineID: machine))
                #expect(modern)
                #expect(receipt.machine == machine)
                #expect(receipt.revision == UInt64.max)
            } catch DaemonError.missingCapabilities(let missing) {
                #expect(!modern)
                #expect(missing == ["agent-inventory-watch-v1"])
            }
            do {
                _ = try await connection.request(MachineAgentInventoryUnwatchRequest(expectedMachineID: machine))
                #expect(modern)
            } catch DaemonError.missingCapabilities(let missing) {
                #expect(!modern)
                #expect(missing == ["agent-inventory-watch-v1"])
            }
            let captured = try await connection.request(CapturedWatchCalls())
            let calls = try #require(captured.arrayValue)
            #expect(calls.count == (modern ? 2 : 0))
            for (index, call) in calls.enumerated() {
                #expect(call["expected_machine_id"] == .string(machine.rawValue))
                #expect(call["enabled"] == .bool(index == 0))
                guard case .object(let fields) = call else { Issue.record("watch request object"); continue }
                #expect(Set(fields.keys) == ["id", "cmd", "enabled", "expected_machine_id"])
            }
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}
