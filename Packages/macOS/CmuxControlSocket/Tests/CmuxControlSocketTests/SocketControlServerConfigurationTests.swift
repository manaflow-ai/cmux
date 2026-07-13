import CmuxControlSocket
import CmuxSettings
import Darwin
import Foundation
import Testing

@MainActor
@Suite("SocketControlServer live configuration")
struct SocketControlServerConfigurationTests {
    @Test func reconfigurePublishesModeAndReappliesPermissionsWithoutRebinding() throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .cmuxOnly))
        let originalIdentity = try #require(fixture.server.transport.pathIdentity(at: fixture.socketPath))
        #expect(try socketPermissions(at: fixture.socketPath) == 0o600)

        fixture.server.reconfigure(accessMode: .allowAll)

        #expect(fixture.server.isRunning)
        #expect(fixture.server.accessMode == .allowAll)
        #expect(fixture.server.transport.pathIdentity(at: fixture.socketPath) == originalIdentity)
        #expect(try socketPermissions(at: fixture.socketPath) == 0o666)
    }

    @Test func reconfigureOffStopsAndUnlinksListener() throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .automation))
        #expect(FileManager.default.fileExists(atPath: fixture.socketPath))

        fixture.server.reconfigure(accessMode: .off)

        #expect(!fixture.server.isRunning)
        #expect(fixture.server.accessMode == .off)
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath))
    }

    private func socketPermissions(at path: String) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let raw = try #require(attributes[.posixPermissions] as? NSNumber)
        return raw.uint16Value
    }
}

@MainActor
private struct SocketConfigurationFixture: ~Copyable {
    let directory: URL
    let socketPath: String
    let server: SocketControlServer

    init() throws {
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scr-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("cmux.sock").path
        server = SocketControlServer(
            initialSocketPath: socketPath,
            events: SocketControlServerEvents(
                breadcrumb: { _, _ in },
                failure: { _, _, _, _ in },
                listenerDidStart: { _, _ in },
                recordLastSocketPath: { _ in },
                pathMissingDetected: { _, _ in },
                rearmRequested: { _, _, _, _ in }
            )
        )
    }

    func shutdown() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
