@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation
import Network
import Testing

/// Parsing of the server's listening sockets (no network).
@Suite struct MobileSSHLoopbackListenerTests {
    @Test func linuxSS() {
        let output = """
        LISTEN 0      4096       127.0.0.1:3000      0.0.0.0:*
        LISTEN 0      511          0.0.0.0:8080      0.0.0.0:*
        LISTEN 0      511            [::1]:5173         [::]:*
        LISTEN 0      128             [::]:22           [::]:*
        LISTEN 0      128     192.168.1.20:9000      0.0.0.0:*
        LISTEN 0      511                *:4000            *:*
        """
        #expect(MobileSSHComputers.loopbackListeners(fromNetstat: output)
            == [3000: "127.0.0.1", 8080: "127.0.0.1", 5173: "::1", 22: "::1", 4000: "127.0.0.1"])
    }

    @Test func macOSNetstat() {
        let output = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  127.0.0.1.3000         *.*                    LISTEN
        tcp6       0      0  ::1.5173               *.*                    LISTEN
        tcp46      0      0  *.8080                 *.*                    LISTEN
        tcp6       0      0  *.9090                 *.*                    LISTEN
        tcp6       0      0  fe80::1%lo0.631        *.*                    LISTEN
        tcp4       0      0  10.0.0.5.22            10.0.0.9.51000         ESTABLISHED
        """
        #expect(MobileSSHComputers.loopbackListeners(fromNetstat: output)
            == [3000: "127.0.0.1", 5173: "::1", 8080: "127.0.0.1", 9090: "::1"])
    }

    @Test func ipv4WinsWhenBothFamiliesListen() {
        let output = "tcp6 0 0 ::1.3000 *.* LISTEN\ntcp4 0 0 127.0.0.1.3000 *.* LISTEN"
        #expect(MobileSSHComputers.loopbackListeners(fromNetstat: output) == [3000: "127.0.0.1"])
    }
}

/// The native browser's network for an SSH computer against the lab sshd
/// (which is this same machine): the SOCKS proxy with server-side DNS, the
/// server's loopback ports mirrored onto the phone's, loop safety when both
/// sides are one machine, and restart after a reconnect.
/// Run with `CMUX_SSH_LAB=/tmp/cmux-ssh-lab`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil))
struct MobileSSHBrowserNetworkLabTests {
    let lab = ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] ?? ""

    /// The lab server is this machine, so every server port is already
    /// held on the "phone" side: the mirror must bind none of them (a
    /// forward there would loop into itself), pages reach them directly,
    /// and non-loopback names go through the proxy with server DNS.
    @Test(.timeLimit(.minutes(1))) func sameMachineMirrorsNothingAndProxyResolvesOnServer() async throws {
        let v6 = try WebServer(bind: "::1", files: ["index.html": "page-ok"])
        let v4 = try WebServer(bind: "127.0.0.1", files: ["data.json": "api-ok"])
        let wildcard = try WebServer(bind: "0.0.0.0", files: ["w.txt": "w-ok"])
        defer { v6.stop(); v4.stop(); wildcard.stop() }
        let (computers, host) = try await makeRuntime()
        defer { Task { @MainActor in await cleanup(computers, host: host) } }
        let answering = autoAnswer(computers)
        defer { answering.cancel() }

        let proxyPort = try await computers.prepareBrowserNetwork(hostID: host.id, loopbackPort: v4.port)
        for port in [v6.port, v4.port, wildcard.port] {
            #expect(computers.loopbackForwards[port] == nil, "mirrored a port this machine holds: \(port)")
        }
        #expect(computers.loopbackForwards[proxyPort] == nil)
        let direct = URLSession(configuration: .ephemeral)
        #expect(try await get(direct, "http://127.0.0.1:\(v4.port)/data.json") == "api-ok")
        #expect(try await get(direct, "http://[::1]:\(v6.port)/index.html") == "page-ok")

        // One page and its API on two ports, by a name the server resolves.
        let proxied = proxiedSession(port: proxyPort)
        #expect(try await get(proxied, "http://app.localhost:\(wildcard.port)/w.txt") == "w-ok")
        #expect(try await get(proxied, "http://app.localhost:\(v4.port)/data.json") == "api-ok")

        // The proxy ends with the connection and returns on the same port.
        await computers.disconnect(hostID: host.id)
        #expect(computers.browserProxies[host.id] == nil)
        #expect(computers.loopbackForwards.isEmpty)
        #expect(try await computers.prepareBrowserNetwork(hostID: host.id, loopbackPort: nil) == proxyPort)
        #expect(try await get(proxiedSession(port: proxyPort), "http://app.localhost:\(v4.port)/data.json") == "api-ok")
    }

    // MARK: Helpers

    private func get(_ session: URLSession, _ url: String) async throws -> String {
        let (data, response) = try await session.data(from: URL(string: url)!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return String(decoding: data, as: UTF8.self)
    }

    /// The proxy setting the native browser's data store uses.
    private func proxiedSession(port: Int) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(port)))
        configuration.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
        return URLSession(configuration: configuration)
    }

    private func makeRuntime() async throws -> (MobileSSHComputers, SSHHostRecord) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-net-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: dir)
        let key = try await computers.importKey(
            label: "lab",
            privateKeyText: try String(contentsOfFile: "\(lab)/client_ed25519", encoding: .utf8),
            passphrase: nil
        )
        let host = SSHHostRecord(
            name: "Lab",
            endpoint: SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()),
            keyID: key.id
        )
        try await computers.saveHost(host)
        return (computers, host)
    }

    private func autoAnswer(_ computers: MobileSSHComputers) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                for prompt in computers.prompts {
                    switch prompt {
                    case .trustNewHostKey: computers.answer(prompt, with: .trust)
                    case .hostKeyChanged: computers.answer(prompt, with: .cancel)
                    }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func cleanup(_ computers: MobileSSHComputers, host: SSHHostRecord) async {
        for key in computers.keys { try? await computers.deleteKey(id: key.id) }
        try? await computers.deleteHost(id: host.id)
    }
}

/// A Python HTTP file server on one address; port 0 lets the OS pick.
private final class WebServer {
    static let script = """
    import http.server, os, socket, sys
    class Server(http.server.ThreadingHTTPServer):
        address_family = socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET
        def server_bind(self):
            if self.address_family == socket.AF_INET6:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            super().server_bind()
    os.chdir(sys.argv[2])
    server = Server((sys.argv[1], 0), http.server.SimpleHTTPRequestHandler)
    print("port", server.server_address[1], flush=True)
    server.serve_forever()
    """
    let port: Int
    private let process = Process()
    private let directory: URL

    init(bind: String, files: [String: String]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-net-www-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, body) in files { try Data(body.utf8).write(to: directory.appendingPathComponent(name)) }
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // IPv6 sockets are IPv6-only, so a `::1` server leaves the IPv4
        // loopback port free (`http.server --bind ::1` would claim both).
        process.arguments = ["python3", "-u", "-c", Self.script, bind, directory.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var banner = ""
        while !banner.contains("\n") {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            banner += String(decoding: chunk, as: UTF8.self)
        }
        guard let range = banner.range(of: #"port (\d+)"#, options: .regularExpression),
              let port = Int(banner[range].dropFirst(5)) else {
            process.terminate()
            throw CocoaError(.fileReadCorruptFile)
        }
        self.port = port
    }

    func stop() {
        process.terminate()
        try? FileManager.default.removeItem(at: directory)
    }
}
