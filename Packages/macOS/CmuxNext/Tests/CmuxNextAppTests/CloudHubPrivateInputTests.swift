import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct CloudHubPrivateInputTests {
    @Test func completedConfigurationReachesTheChildWithoutAConfigFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("hub")
        try """
            #!/bin/sh
            while [ $# -gt 0 ]; do
              case "$1" in --config) C=$2 ;; --socket) S=$2 ;; esac
              shift
            done
            [ "$C" = - ] || exit 41
            INPUT=$(/bin/cat)
            case "$INPUT" in *'PrivateKey = '*) ;; *) exit 42 ;; esac
            printf '{"event":"hub-ready","socket":"%s","routes":[]}\\n' "$S"
            exec /bin/sleep 60
            """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let config = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"], process: [:], isDebugBuild: true)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CloudLinkReconnectingTests.StandInVMAPI.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let api = CloudAPIClient(configuration: config, tokens: { ("access", "refresh") }, teamID: { nil }, session: session)
        let paths = CloudPaths(root: root.appendingPathComponent("cloud"))
        let hub = CloudTunnelHub(api: api, paths: paths, binary: binary, deviceName: "private-input-test")
        var ready: String?
        do { ready = try await hub.socketPath() } catch { Issue.record("hub refused the in-memory handoff") }
        await hub.stop()
        #expect(ready == paths.hubSocket)
        #expect(!FileManager.default.fileExists(atPath: paths.wireGuardConfig.path))
    }
}
