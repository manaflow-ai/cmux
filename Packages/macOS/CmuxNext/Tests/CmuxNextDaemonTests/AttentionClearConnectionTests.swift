import Foundation
import Testing
@testable import CmuxNextDaemon

/// The transport that sends attention:null must itself advertise guarded clears.
/// A store's earlier handshake is insufficient across a daemon handoff.
struct AttentionClearConnectionTests {
    private struct Calls: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-attention-calls"
    }

    @Test(arguments: [false, true])
    func theSendingConnectionRequiresTheGuardCapability(modern: Bool) async throws {
        let script = #"""
        import json, sys
        modern = sys.argv[1] == 'yes'
        calls = []
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            result = {}
            if frame.get('cmd') == 'identify':
                result = {'app':'cmux-tui','protocol':12,'generation':'attention-boot',
                    'capabilities':['tab-attention-v1','tab-attention-request-id-v1'] if modern else ['tab-attention-v1']}
            elif frame.get('operation') == 'tab.update':
                calls.append(frame)
                print(json.dumps({'id':frame['id'],'ok':True,'result':{'value':{}}}), flush=True)
                continue
            elif frame.get('cmd') == 'test-attention-calls':
                result = calls
            print(json.dumps({'id':frame.get('id'),'ok':True,'data':result}), flush=True)
        """#
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, modern ? "yes" : "no"])
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-attention-test-\(UUID().uuidString).sock", bridge: bridge)
        let connection = DaemonConnection(endpoint: endpoint, configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        let token = String(repeating: "a", count: 32)
        do {
            try await connection.start()
            do {
                try await connection.state.updateTabRecord("tab_attention", attentionRequestID: token)
                #expect(modern)
            } catch DaemonError.missingCapabilities(let missing) {
                #expect(!modern)
                #expect(missing == [DaemonCapability.tabAttentionRequestID.rawValue])
            }
            let calls = try #require(try await connection.request(Calls()).arrayValue)
            #expect(calls.count == (modern ? 1 : 0), "a legacy sender received an unguarded clear")
            if let call = calls.first {
                #expect(call["params"]?["attention"] == .null)
                #expect(call["params"]?["attention_request_id"] == .string(token))
            }
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}
