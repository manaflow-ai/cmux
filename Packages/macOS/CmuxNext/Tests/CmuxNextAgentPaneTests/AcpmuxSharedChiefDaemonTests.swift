import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Tagged DEV builds share the account's Chief home, so one build's acpmux serves them all. Another
/// DEV build's bundled acpmux is accepted there (rules 2 and 3 still apply), and a daemon the peer
/// check refuses is named in the error instead of "acpmux did not start" with a silent log.
@Suite(.serialized)
struct AcpmuxSharedChiefDaemonTests {
    private let own = URL(fileURLWithPath:
        "/Users/u/Library/Developer/Xcode/DerivedData/cmux-a/Build/Products/Debug/cmux DEV a.app/Contents/Resources/bin/acpmux")
    private let otherBuild =
        "/Users/u/Library/Developer/Xcode/DerivedData/cmux-b/Build/Products/Debug/cmux DEV nxdog98-v1.app/Contents/Resources/bin/acpmux"

    @Test func anotherDevBuildsBundledAcpmuxIsAccepted() {
        #expect(AcpmuxServerPeer.otherBuildsBundledAcpmux(peerPath: otherBuild, ownExecutable: own))
        #expect(AcpmuxServerPeer.otherBuildsBundledAcpmux(
            peerPath: "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux", ownExecutable: own))
    }

    @Test(arguments: [
        "/usr/local/bin/acpmux",
        "/Users/u/.cargo/bin/acpmux",
        "/Applications/Other.app/Contents/Resources/bin/acpmux",
        "/Applications/cmux.app/Contents/Resources/bin/sh",
        "/Applications/cmux.app/Contents/MacOS/acpmux",
    ])
    func anythingElseIsRefused(peerPath: String) {
        #expect(!AcpmuxServerPeer.otherBuildsBundledAcpmux(peerPath: peerPath, ownExecutable: own))
    }

    @Test func anAppThatDoesNotRunItsBundledAcpmuxAcceptsNoOtherBuild() {
        #expect(!AcpmuxServerPeer.otherBuildsBundledAcpmux(
            peerPath: otherBuild, ownExecutable: URL(fileURLWithPath: "/usr/local/bin/acpmux")))
    }

    @Test func theHolderIsTheAppThatBundlesTheDaemon() {
        #expect(AcpmuxServerPeer.holderName(executablePath: otherBuild) == "cmux DEV nxdog98-v1")
        #expect(AcpmuxServerPeer.holderName(executablePath: "/usr/local/bin/acpmux") == "/usr/local/bin/acpmux")
    }

    @Test func theMessageNamesTheBuildAndTheSocket() {
        let message = AgentPaneHostError.userMessage(
            for: AgentPaneHostError.daemonRefused(holder: "cmux DEV nxdog98-v1", socketPath: "/h/acpmux.sock", reason: "r"))
        #expect(message.contains("cmux DEV nxdog98-v1"))
        #expect(message.contains("/h/acpmux.sock"))
        #expect(!message.contains("did not start"))
    }

    /// The end-to-end path of the bug: a daemon answers on the Chief home's socket but is not the
    /// acpmux this app runs. The Chief's host (it never starts a daemon) reports who holds it.
    @Test func aRefusedDaemonIsNamedNotReportedAsNotStarted() async throws {
        let root = URL(fileURLWithPath: "/tmp/asc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let acpmux = bin.appendingPathComponent("acpmux")
        try "#!/bin/sh\nexit 1\n".write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        let socketPath = home.appendingPathComponent("s.sock").path
        let environment = try #require(AcpmuxEnvironment.resolve(
            tag: nil, bundledBinDirectory: bin, environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socketPath]))
        let server = try FakeDaemon(socketPath: socketPath)
        defer { server.stop() }

        let host = AcpmuxHost(environment: environment, startsDaemons: false)
        do {
            _ = try await host.reconnectHandshake(sessionId: "s")
            Issue.record("a daemon that is not this app's acpmux was accepted")
        } catch let error as AgentPaneHostError {
            guard case .daemonRefused(_, let path, let reason) = error else {
                Issue.record("expected daemonRefused, got \(error)")
                return
            }
            #expect(path == socketPath)
            #expect(!reason.isEmpty)
        }
    }
}

/// A unix socket served by this test process that answers every JSON-RPC request with a status.
private nonisolated final class FakeDaemon: @unchecked Sendable {  // the fd is written once in init and closed once in stop
    private let descriptor: Int32
    private let path: String

    init(socketPath: String) throws {
        path = socketPath
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        let listener = descriptor
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { Self.serve(client) }
            }
        }
    }

    private static func serve(_ client: Int32) {
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
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] else { continue }
                let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": [
                    "webUrl": "ws://127.0.0.1:9/?token=t", "pid": Int(getpid()), "build": "other", "agentHosts": true,
                ]]
                guard var data = try? JSONSerialization.data(withJSONObject: reply) else { continue }
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
