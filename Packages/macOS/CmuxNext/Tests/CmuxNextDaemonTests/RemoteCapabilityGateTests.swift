import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// Commands the app sends only to daemons that report the capability. A
/// Cloud machine still on its image's cmux-tui (3412812) has none of the
/// cmux-next capabilities; sending such a command there fails with an
/// "unknown variant" error the user cannot act on.
@Suite(.timeLimit(.minutes(1))) struct RemoteCapabilityGateTests {
    @Test func tabPinOnADaemonWithoutTabMetadataIsATypedCapabilityErrorAndSendsNothing() async throws {
        let seen = Mutex<[String]>([])
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, id in
            let cmd = request["cmd"]?.stringValue ?? ""
            seen.withLock { $0.append(cmd) }
            return [#"{"ok":false,"error":"bad request: unknown variant `\#(cmd)`"}"#]
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        await #expect(throws: DaemonError.missingCapabilities([DaemonCapabilities.tabMetadata])) {
            _ = try await connection.setTabPinned(SurfaceID(rawValue: 3), true)
        }
        #expect(!seen.withLock { $0 }.contains("set-tab-pinned"))
        await connection.close()
    }
}
