import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApps

/// Exercises the actual connection adapter and wire capability gate through a test-only bridge.
struct MachineCatalogConnectionTests {
    private struct CaptureRequest: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-catalog-attempts"
    }

    @Test(arguments: ["legacy", "modern", "wrong-owner"])
    func publicationUsesTheNegotiatedConnectionWithoutFallback(mode: String) async throws {
        let script = #"""
        import json, sys
        mode = sys.argv[1]
        attempts = []
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            command = frame.get('cmd')
            result = {}
            code = None
            if command == 'identify':
                result = {'app':'cmux-tui','protocol':12,'generation':'catalog-test',
                    'machine_id':'machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                    'capabilities':[] if mode == 'legacy' else ['machine-catalog-publish-v1']}
            elif command == 'machine-catalog-publish':
                attempts.append(frame)
                if mode == 'wrong-owner':
                    code = 'machine_catalog.owner_mismatch'
            elif command == 'test-catalog-attempts':
                result = attempts
            reply = {'id':frame.get('id'),'ok':code is None,'data':result}
            if code:
                reply.update(error='wrong owner', error_code=code)
            print(json.dumps(reply), flush=True)
        """#
        let bridge = DaemonBridge.fakePython(["-c", script, mode])
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-catalog-test-\(UUID().uuidString).sock", bridge: bridge),
                                          configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        let request = MachineCatalogPublishRequest(expectedMachineID: "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", sequence: 7, machines: [])
        do {
            try await connection.start()
            do {
                let writer: any MachineCatalogWriter = connection
                try await writer.publishMachineCatalog(request)
                #expect(mode == "modern")
            } catch DaemonError.missingCapabilities(let missing) {
                #expect(mode == "legacy" && missing == ["machine-catalog-publish-v1"])
            } catch DaemonError.command(_, _, let code, _, _) {
                #expect(mode == "wrong-owner" && code == "machine_catalog.owner_mismatch")
            }
            let attempts = try await connection.request(CaptureRequest())
            guard case .array(let frames) = attempts else {
                Issue.record("missing capture"); await connection.close(); return
            }
            #expect(frames.count == (mode == "legacy" ? 0 : 1))
            if let frame = frames.first {
                #expect(frame["expected_machine_id"] == .string(request.expectedMachineID.rawValue))
                #expect(frame["sequence"] == .number(7))
                #expect(frame["machines"] == .array([]))
                #expect(frame["cmd"] == .string("machine-catalog-publish"))
            }
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}
