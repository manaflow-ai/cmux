@testable import CmuxCloud
import CmuxCloudTui
import Foundation
import Testing

/// A link must retire when its event subscription cannot reach the daemon.
/// Otherwise connect reports success while the manager keeps a dead process.
@Suite("Cloud machine link transport recovery")
struct CloudMachineLinkTransportRecoveryTests {
    @Test("Invalid protocol responses do not report a lost daemon transport")
    func invalidResponseKeepsLinkRecoverable() async {
        let invalidChannel = CloudTuiPersistentResourceConnection(socketPath: "/unused")
        await invalidChannel.close(invalidResponse: true)
        // The socket pump also calls close when its stream finishes; it must
        // retain the original invalid-response reason.
        await invalidChannel.close()
        #expect(await invalidChannel.isClosed)
        #expect(!(await invalidChannel.lostTransport))

        let lostChannel = CloudTuiPersistentResourceConnection(socketPath: "/unused")
        await lostChannel.close()
        #expect(await lostChannel.lostTransport)
    }

    /// A refused event socket must release the stale link so the manager can
    /// establish a fresh client on refresh.
    @Test("A refused event socket retires the live link")
    func refusedEventSocketRetiresLink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fence-\(UUID().uuidString.prefix(8))", isDirectory: true)
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

        var failed = false
        do {
            _ = try await link.connect(route: "ws://10.0.0.1:1337/v1/link", session: "main", carrier: true)
            Issue.record("the missing daemon socket must fail the event subscription")
        } catch {
            failed = true
        }

        #expect(failed)
        #expect(!(await link.isConnected))
        #expect(await link.state == .error)
        #expect(await link.lastError == CloudMachineLink.errorText(CloudMachineLink.LinkError.transportLost))
        #expect(await link.lastError?.contains("missing-daemon.sock") == false)
        var sawTransportStreamEnd = false
        for await change in link.changes {
            if case .streamEnded("transport_failure", _) = change {
                sawTransportStreamEnd = true
            }
        }
        #expect(sawTransportStreamEnd)
        await link.disconnect()
    }
}
