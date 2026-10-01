@testable import CmuxCloud
import CmuxCloudTui
import Foundation
import Testing

/// A live link must retire when its local control socket becomes unreachable.
/// Otherwise the manager keeps returning the old process forever and no refresh
/// can create a replacement client.
@Suite("Cloud machine link transport recovery")
struct CloudMachineLinkTransportRecoveryTests {
    /// A control request against a missing daemon socket must release the
    /// stale link so the manager can establish a fresh client on refresh.
    @Test("A refused control socket retires the live link")
    func refusedControlSocketRetiresLink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-link-transport-fence-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("fake-cmux-tui")
        let socket = root.appendingPathComponent("missing-daemon.sock")
        try """
        #!/bin/sh
        printf '%s\\n' '{"event":"connection-snapshot","local_socket":"\(socket.path)"}'
        sleep 5
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let link = CloudMachineLink(machineID: "test-machine", clientURL: client, paths: CloudTuiClientPaths(home: root))

        _ = try await link.connect(route: "ws://10.0.0.1:1337/v1/link", session: "main", carrier: true)
        var failed = false
        do {
            _ = try await link.run(arguments: CloudTuiRequests.snapshotArguments(socketPath: socket.path))
            Issue.record("the missing daemon socket must fail the control request")
        } catch let error as NSError {
            failed = true
            #expect(error.domain == "cmux.cloud.manual-io")
        }

        #expect(failed)
        #expect(!(await link.isConnected))
        #expect(await link.state == .error)
        #expect(await link.lastError == "The Cloud VM service connection was lost. Refresh to reconnect.")
        #expect(await link.lastError?.contains("missing-daemon.sock") == false)
        await link.disconnect()
    }
}
