import Darwin
import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// DEV's `CMUX_NEXT_ACPMUX_ATTACH`: which builds attach to another app's daemon, and that an
/// attached host never starts, hands off or upgrades it.
@Suite(.serialized)
struct AcpmuxAttachTests {
    private static let user = URL(fileURLWithPath: "/Users/dev", isDirectory: true)
    private static let dev = BuildIdentity(bundleID: "com.cmuxterm.app.debug.attach", bundledTag: nil)

    private static func home(_ value: String?, build: BuildIdentity? = dev) -> String? {
        AcpmuxEnvironment.attachHome(build: build, environment: value.map { [AcpmuxEnvironment.attachKey: $0] } ?? [:],
                                     userHome: user)?.path
    }

    @Test func offUnlessSet() {
        #expect(Self.home(nil) == nil)
        #expect(Self.home("") == nil)
        #expect(Self.home("  ") == nil)
    }

    @Test func aDevBuildAttachesToAnAbsoluteOrTildeHome() {
        #expect(Self.home("/Users/dev/.acpmux") == "/Users/dev/.acpmux")
        #expect(Self.home("~/.acpmux/") == "/Users/dev/.acpmux")
        #expect(Self.home("~") == "/Users/dev")
    }

    @Test func aRelativePathIsIgnored() {
        #expect(Self.home(".acpmux") == nil)
        #expect(Self.home("~other/.acpmux") == nil)
    }

    @Test func onlyADevIdentityAttaches() {
        // NEXT DEV (a Release compile) and tagged DEV builds.
        for bundle in ["com.cmuxterm.app.debug", "com.cmuxterm.app.debug.next", "com.cmuxterm.app.debug.my-tag"] {
            #expect(Self.home("~/.acpmux", build: BuildIdentity(bundleID: bundle, bundledTag: nil)) == "/Users/dev/.acpmux", "\(bundle)")
        }
        for bundle in ["com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app",
                       "com.cmuxterm.app.rc", "com.cmuxterm.app.staging.x"] {
            #expect(Self.home("~/.acpmux", build: BuildIdentity(bundleID: bundle, bundledTag: nil)) == nil, "\(bundle) attached")
        }
        #expect(Self.home("~/.acpmux", build: nil) == nil)
    }

    @Test func attachedPointsAtThatDaemonsSocket() throws {
        let own = try #require(AcpmuxEnvironment.resolve(
            build: Self.dev, bundledBinDirectory: nil, environment: ["PATH": "/bin"], userHome: Self.user, uid: 501,
            isExecutable: { _ in true }, executableOverride: nil, teamIdentifier: nil))
        #expect(!own.isAttached)
        let attached = own.attached(to: URL(fileURLWithPath: "/Users/dev/.acpmux", isDirectory: true), uid: 501)
        #expect(attached.isAttached)
        #expect(attached.home.path == "/Users/dev/.acpmux")
        #expect(attached.socketPath == "/Users/dev/.acpmux/acpmux.sock")
        #expect(attached.childEnvironment["ACPMUX_HOME"] == "/Users/dev/.acpmux")
        #expect(attached.childEnvironment["ACPMUX_SOCKET"] == "/Users/dev/.acpmux/acpmux.sock")
        #expect(attached.daemonArguments.isEmpty)
    }

    /// A stand-in `acpmux` that records each launch, and the attached home with a crashed
    /// daemon's `daemon.pid` (an owned host's reconnect would start one there).
    private static func fixture() throws -> (root: URL, environment: AcpmuxEnvironment) {
        let root = URL(fileURLWithPath: "/tmp/aat-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let acpmux = bin.appendingPathComponent("acpmux")
        try "#!/bin/sh\ntouch '\(root.path)/launched'\nexit 1\n".write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        let own = try #require(AcpmuxEnvironment.resolve(
            build: nil, bundledBinDirectory: bin, environment: ["ACPMUX_HOME": root.appendingPathComponent("own").path],
            executableOverride: nil, teamIdentifier: nil))
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        try "\(gone.processIdentifier)".write(to: home.appendingPathComponent("daemon.pid"), atomically: true, encoding: .utf8)
        return (root, own.attached(to: home))
    }

    @Test func anAttachedHostNeverStartsADaemon() async throws {
        let (root, environment) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = AcpmuxHost(resolve: { environment })

        await #expect(throws: AgentPaneHostError.daemonStopped) { _ = try await host.handshake(sessionId: nil) }
        await #expect(throws: AgentPaneHostError.daemonStopped) { _ = try await host.reconnectHandshake(sessionId: "s") }
        await #expect(throws: AgentPaneHostError.daemonStopped) { try await host.prewarm() }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path),
                "an attached DEV build started a daemon in another app's home")
    }

    /// A running daemon of the attached home only answers status: the host sends no person key,
    /// Computer Use enrollment, handoff or shutdown, and writes nothing to that home's log.
    @Test func anAttachedHostOnlyReadsARunningDaemon() async throws {
        let (root, environment) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = try RecordingDaemon(socketPath: environment.socketPath, home: environment.home.path)
        defer { daemon.stop() }
        let host = AcpmuxHost(resolve: { environment })

        _ = try? await host.handshake(sessionId: nil)
        _ = try? await host.reconnectHandshake(sessionId: "s")
        #expect(!daemon.methods.isEmpty)
        #expect(daemon.methods.allSatisfy { ["initialize", "_acpmux/status"].contains($0) }, "sent \(daemon.methods)")
        #expect(!FileManager.default.fileExists(atPath: environment.home.appendingPathComponent("daemon.log").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path))
    }
}

/// A unix socket served by this test process that records each request's method and answers
/// with a status of `home`.
nonisolated final class RecordingDaemon: @unchecked Sendable {  // the fd is written once in init and closed once in stop
    private let descriptor: Int32
    private let path: String
    private let recorded = Mutex<[String]>([])
    var methods: [String] { recorded.withLock { $0 } }

    init(socketPath: String, home: String) throws {
        path = socketPath
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { self.serve(client, home: home) }
            }
        }
    }

    private func serve(_ client: Int32, home: String) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer += Data(chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] else { continue }
                recorded.withLock { $0.append(object["method"] as? String ?? "") }
                let result: [String: Any] = ["webUrl": "ws://127.0.0.1:9/?token=t", "pid": Int(getpid()), "build": "other",
                                             "agentHosts": true, "home": home]
                guard var data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
                else { continue }
                data.append(0x0A)
                _ = data.withUnsafeBytes { send(client, $0.baseAddress, data.count, 0) }
            }
        }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }
}
