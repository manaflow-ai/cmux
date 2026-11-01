import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A daemon that answers on this app's acpmux socket but that this build may not use (the peer
/// check refuses it, or it serves another acpmux home) is named in the error, never reported as
/// "acpmux did not start" with a log that says nothing.
@Suite(.serialized)
struct AcpmuxRefusedDaemonTests {
    private let otherBuild =
        "/Users/u/Library/Developer/Xcode/DerivedData/cmux-b/Build/Products/Debug/cmux DEV nxdog98-v1.app/Contents/Resources/bin/acpmux"

    @Test func theHolderIsTheAppThatBundlesTheDaemon() {
        #expect(AcpmuxServerPeer.holderName(executablePath: otherBuild) == "cmux DEV nxdog98-v1")
        #expect(AcpmuxServerPeer.holderName(executablePath: "/usr/local/bin/acpmux") == "/usr/local/bin/acpmux")
    }

    /// The copy #24795 settled on names the build that holds acpmux, not the socket path.
    @Test func theMessageNamesTheBuild() {
        let message = AgentPaneHostError.userMessage(
            for: AgentPaneHostError.daemonRefused(holder: "cmux DEV nxdog98-v1", socketPath: "/h/acpmux.sock", reason: "r"))
        #expect(message.contains("cmux DEV nxdog98-v1"))
        #expect(!message.contains("did not start"))
    }

    /// A live peer from another cmux build remains a real refusal. The person may quit that
    /// build and press Retry, but the app never asks them to paste a shell command.
    @Test(arguments: [nil, "cmux DEV nxdog98-v1"] as [String?])
    func everyRefusalNamesTheBuildWithoutACommand(holder: String?) {
        let error = AgentPaneHostError.daemonRefused(
            holder: holder, socketPath: "/Users/u/.acpmux/acpmux.sock",
            reason: "the socket's peer is not signed by this app's team",
            executable: "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux")
        let message = AgentPaneHostError.userMessage(for: error)
        #expect(!message.contains("Run this in a terminal"))
        #expect(!message.contains("ACPMUX_SOCKET="))
        #expect(!message.contains("daemon shutdown"))
        #expect(!message.contains("did not start"))
        if let holder {
            #expect(message.contains(holder))
            #expect(message.contains("Quit"))
            #expect(message.contains("try again"))
        }
    }

    @Test func aMissingSocketIsTransientDuringAHandOff() {
        #expect(AcpmuxServerPeer.Refusal.unreachable("No such file or directory").isTransientRestart)
        #expect(!AcpmuxServerPeer.Refusal.otherExecutable("/tmp/other-acpmux").isTransientRestart)
    }

    /// The refusal the host makes carries this app's own acpmux, so the command never runs the
    /// refused daemon's binary or a stray one on PATH.
    @Test func theHostsRefusalNamesThisAppsAcpmux() async throws {
        let (_, _, executable) = try await refusalWithExecutable(daemonHome: nil)
        #expect(executable.hasSuffix("/bin/acpmux"))
    }

    /// The end-to-end path of the bug: a daemon answers on the socket but is not the acpmux this
    /// app runs. A reconnect (it never starts a daemon) reports who holds it.
    @Test func aRefusedDaemonIsNamedNotReportedAsNotStarted() async throws {
        let (_, reason) = try await refusal(daemonHome: nil)
        #expect(!reason.isEmpty)
    }

    /// A daemon of another acpmux home on this app's socket (an inherited `ACPMUX_SOCKET`) is
    /// refused and named with that home, not reported as "acpmux did not start".
    @Test func aDaemonOfAnotherHomeIsNamedNotReportedAsNotStarted() async throws {
        let (_, reason) = try await refusal(daemonHome: "/tmp/another-acpmux-home")
        #expect(reason.contains("/tmp/another-acpmux-home"))
    }

    /// Runs a reconnect against a fake daemon (this test process, never this app's acpmux) that
    /// reports `daemonHome`, and returns the refused socket path and reason.
    private func refusal(daemonHome: String?) async throws -> (String, String) {
        let (path, reason, _) = try await refusalWithExecutable(daemonHome: daemonHome)
        return (path, reason)
    }

    private func refusalWithExecutable(daemonHome: String?) async throws -> (String, String, String) {
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
            build: nil, bundledBinDirectory: bin, environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socketPath],
            executableOverride: nil))
        let server = try FakeDaemon(socketPath: socketPath, home: daemonHome)
        defer { server.stop() }

        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: environment, startsDaemons: false)
        do {
            _ = try await host.reconnectHandshake(sessionId: "s")
            Issue.record("a daemon that is not this app's acpmux was accepted")
        } catch let error as AgentPaneHostError {
            guard case .daemonRefused(_, let path, let reason, let executable, _) = error else {
                Issue.record("expected daemonRefused, got \(error)")
                return ("", "", "")
            }
            #expect(path == socketPath)
            #expect(!AgentPaneHostError.userMessage(for: error).contains("did not start"))
            return (path, reason, executable)
        }
        return ("", "", "")
    }
}

/// A unix socket served by this test process that answers every JSON-RPC request with a status.
/// ``calls`` lists the methods each connection sent, by connection, in order.
nonisolated final class FakeDaemon: @unchecked Sendable {  // the fd is written once in init and closed once in stop; `recorded` only under `lock`
    private let descriptor: Int32
    private let path: String
    private let lock = NSLock()
    private var recorded: [[String]] = []

    var calls: [[String]] { lock.withLock { recorded } }

    init(socketPath: String, home: String? = nil, agentHosts: Bool = true) throws {
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
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                let connection = lock.withLock { recorded.append([]); return recorded.count - 1 }
                let record: @Sendable (String) -> Void = { [self] method in lock.withLock { recorded[connection].append(method) } }
                Thread.detachNewThread { Self.serve(client, home: home, agentHosts: agentHosts, record: record) }
            }
        }
    }

    private static func serve(_ client: Int32, home: String?, agentHosts: Bool, record: @Sendable (String) -> Void) {
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
                record(object["method"] as? String ?? "")
                var result: [String: Any] = [
                    "webUrl": "ws://127.0.0.1:9/?token=t", "pid": Int(getpid()), "build": "other", "agentHosts": agentHosts,
                ]
                if let home { result["home"] = home }
                let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
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
