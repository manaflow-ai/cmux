import Foundation
import Testing
@testable import CmuxNextDaemon

struct MachineIdentityHandshakeTests {
    private struct CaptureRequest: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-identity-attempts"
    }

    @Test(arguments: ["legacy", "modern", "changed-boot"], ["none", "role", "proof"])
    func ownerMetadataRequiresAdvertisement(mode: String, handshake: String) async throws {
        let modern = mode != "legacy"
        let withHello = handshake != "none"
        let key = handshake == "proof" ? FrontendInstallKey.generate() : nil
        let script = #"""
        import json, sys
        mode = sys.argv[1]
        modern = mode != 'legacy'
        attempts = []
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            command = frame.get('cmd')
            result = {}
            ok = True
            if command == 'test-identity-attempts':
                result = attempts
            else:
                attempts.append(frame)
            if command == 'identify':
                ok = modern or 'machine_metadata' not in frame
                result = {'app':'cmux-tui','protocol':12,'generation':'identity-test',
                    'capabilities':['machine-identity-v1'] if modern else []}
                if modern and frame.get('machine_metadata') is True:
                    if mode == 'changed-boot':
                        result['generation'] = 'replacement-boot'
                    result.update(machine_id='machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                        machine_platform={'os':'linux'}, machine_capabilities=['terminal'])
            elif command == 'client-hello':
                result = {'connection_id':'test-client'}
                if 'proof' in frame:
                    result.update(verified=True, user_origin_allowed=True)
                elif 'install_id' in frame:
                    result['nonce'] = '00' * 32
            reply = {'id':frame.get('id'),'ok':ok,'data':result}
            if not ok:
                reply.update(error='unknown identify field', error_code='bad-request')
            print(json.dumps(reply), flush=True)
        """#
        let bridge = DaemonBridge.fakePython(["-c", script, mode])
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-identity-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], terminalEnvironment: nil, clientHello: withHello ? .init(installKey: key) : nil))
        do {
            if mode == "changed-boot" {
                do {
                    try await connection.start()
                    Issue.record("metadata replaced the original handshake generation")
                } catch DaemonError.malformedResponse { }
                await connection.close()
                return
            }
            try await connection.start()
            let identity = await connection.identity
            #expect(identity?.machineResourceID?.rawValue == (modern ? "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" : nil))
            let attempts = try await connection.request(CaptureRequest())
            let frames = try #require(attempts.arrayValue)
            let reads = frames.filter { $0["cmd"] == .string("identify") }
            #expect(reads.count == (modern ? 2 : 1))
            #expect(reads[0]["machine_metadata"] == nil)
            if modern { #expect(reads[1]["machine_metadata"] == .bool(true)) }
            if withHello && modern {
                #expect(frames[1]["cmd"] == .string("client-hello"))
                let metadataIndex = key == nil ? 2 : 3
                if key != nil {
                    #expect(frames[2]["cmd"] == .string("client-hello"))
                    #expect(frames[2]["proof"] != nil)
                }
                #expect(frames[metadataIndex]["cmd"] == .string("identify"))
                #expect(frames[metadataIndex + 1]["cmd"] == .string("set-client-info"))
            }
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}
