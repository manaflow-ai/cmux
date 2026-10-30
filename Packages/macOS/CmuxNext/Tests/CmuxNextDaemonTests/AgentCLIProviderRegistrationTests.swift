import Foundation
import Testing
@testable import CmuxNextDaemon

/// Exercises the real connection handshake, admission and encoded registration
/// against a bounded test bridge; it never launches a user daemon or app.
struct AgentCLIProviderRegistrationTests {
    @Test(arguments: [false, true])
    func registrationPreservesLegacyFamiliesAndNegotiatesAgentCLI(modern: Bool) async throws {
        let families = ["coderouter", "agent_cli", "action"]
        let result = try await registration(modern: modern, families: families)
        let expected = modern ? families : ["coderouter", "action"]
        #expect(result["families"] == .array(expected.map(JSONValue.string)))
        #expect(result["attempts"] == .array([.array(expected.map(JSONValue.string))]))
    }

    private func registration(modern: Bool, families: [String]) async throws -> JSONValue {
        let script = #"""
        import json, sys
        caps = json.loads(sys.argv[1])
        attempts = []
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            command = frame.get('cmd')
            result = {}
            ok = True
            if command == 'identify':
                result = {'app':'cmux-tui','protocol':12,'generation':'test-boot','capabilities':caps}
            elif command == 'apps-provider-register':
                requested = frame['families']
                attempts.append(requested)
                ok = 'agent_cli' not in requested or 'agent-cli-app-provider-v1' in caps
                result = {'families':requested,'attempts':attempts}
            reply = {'id':frame.get('id'),'ok':ok,'data':result}
            if not ok:
                reply.update(error='unknown provider family',error_code='bad-request')
            print(json.dumps(reply), flush=True)
        """#
        let caps = modern ? ["apps-v1", "agent-cli-app-provider-v1"] : ["apps-v1"]
        let encoded = String(decoding: try JSONEncoder().encode(caps), as: UTF8.self)
        let bridge = DaemonBridge.fakePython(["-c", script, encoded])
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-provider-test-\(UUID().uuidString).sock", bridge: bridge)
        let connection = DaemonConnection(endpoint: endpoint, configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            try await connection.start()
            let result = try await AppProviderRegistration(connection: connection).register(families: families)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }
}
