import CmuxMobileSSH
import Foundation
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil))
struct SSHPortForwardLabTests {
    let lab = ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] ?? ""

    @Test func localForwardReachesServerLocalhostWebServer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-fwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("forwarded-ok".utf8).write(to: dir.appendingPathComponent("index.html"))
        let port = Int.random(in: 41000...48000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", dir.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        try await Task.sleep(for: .milliseconds(600))

        let key = try SSHParsedPrivateKey(openSSH: try String(contentsOfFile: "\(lab)/client_ed25519", encoding: .utf8)).key
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()),
            credentials: [.privateKey(key)],
            hostKeyVerifier: RecordingVerifier(accept: true)
        )
        let forward = try await SSHLocalPortForward.start(over: connection, targetPort: port)
        #expect(forward.localPort > 0)
        for _ in 0..<3 {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(forward.localPort)/index.html")!)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self) == "forwarded-ok")
        }
        await forward.stop()
        await connection.close()
    }
}
