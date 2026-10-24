import CmuxNextBrowser
import CmuxNextRemoteLocalhost
import CmuxNextRemoteLocalhostService
import Darwin
import Foundation
import Testing

/// Open Desktop's route (HubLoopbackOpener): a Cloud machine's localhost goes through the app's
/// WireGuard hub as SOCKS5 to the machine's private address, the way cmux-tui's `wg hub` serves
/// its links, presenting the hub's per-launch client token (RFC 1929 username/password). A
/// stand-in hub on a Unix socket checks the bytes and the token, and echoes the stream.
@Suite(.serialized)
struct CloudHubLoopbackTests {
    /// One connection's SOCKS5 server: greeting, the token `cmux-hub-token`, then CONNECT, answered
    /// `reply`; after a success it echoes. A wrong token is answered with an auth failure.
    /// Nonisolated: this target defaults to the main actor, and its accept loop runs on its own thread.
    nonisolated final class FakeHub: @unchecked Sendable {
        let path = "/tmp/cmux-hubtest-\(UUID().uuidString.prefix(8)).sock"
        private let listener: Int32
        static let token = "cmux-hub-token"
        private let lock = NSLock()
        private var connect = Data()

        var connectRequest: Data { lock.withLock { connect } }

        init(reply: UInt8) throws {
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            listener = fd
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(fd, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
            Thread.detachNewThread { [self] in
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                guard Self.read(client, 3) == Data([0x05, 0x01, 0x02]) else { return }
                Self.write(client, Data([0x05, 0x02]))
                guard Self.read(client, 2) == Data([0x01, 0x04]), Self.read(client, 4) == Data("cmux".utf8) else { return }
                let length = Self.read(client, 1)
                guard let count = length.first, Self.read(client, Int(count)) == Data(Self.token.utf8) else {
                    Self.write(client, Data([0x01, 0x01]))
                    return
                }
                Self.write(client, Data([0x01, 0x00]))
                let request = Self.read(client, 10)
                lock.withLock { connect = request }
                Self.write(client, Data([0x05, reply, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                guard reply == 0 else { return }
                var byte = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(client, &byte, byte.count)
                    guard count > 0 else { return }
                    Self.write(client, Data(byte[0..<count]))
                }
            }
        }

        deinit {
            close(listener)
            unlink(path)
        }

        private static func read(_ fd: Int32, _ count: Int) -> Data {
            var data = Data()
            var byte = [UInt8](repeating: 0, count: count)
            while data.count < count {
                let got = Darwin.read(fd, &byte, count - data.count)
                guard got > 0 else { break }
                data.append(contentsOf: byte[0..<got])
            }
            return data
        }

        private static func write(_ fd: Int32, _ data: Data) {
            data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, data.count) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func theMachinesLocalhostGoesToItsPrivateAddressThroughTheHub() async throws {
        let hub = try FakeHub(reply: 0x00)
        let path = hub.path
        let made = HubLoopbackOpener(hub: { .init(socket: path, token: FakeHub.token) }, address: "10.149.25.1")
        let opener = try #require(made)
        let tunnel = try await opener.openTunnel(host: "vm-test.cloud-desktop.localhost", port: 6901)
        // CONNECT, IPv4 10.149.25.1, port 6901: the machine's noVNC on its Cloud network.
        #expect(hub.connectRequest == Data([0x05, 0x01, 0x00, 0x01, 10, 149, 25, 1, 0x1A, 0xF5]))
        try await tunnel.write(Data("ping".utf8))
        var echoed = Data()
        for await event in tunnel.events {
            if case .data(let data) = event { echoed.append(data); tunnel.consumed(data.count) }
            if echoed.count >= 4 { break }
        }
        #expect(echoed == Data("ping".utf8))
        tunnel.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusalFromTheHubIsRefused() async throws {
        let hub = try FakeHub(reply: 0x05)
        let path = hub.path
        let made = HubLoopbackOpener(hub: { .init(socket: path, token: FakeHub.token) }, address: "10.149.25.1")
        let opener = try #require(made)
        await #expect(throws: LoopbackTunnelFailure.refused) { _ = try await opener.openTunnel(host: "localhost", port: 6901) }
    }

    @Test(.timeLimit(.minutes(1)))
    func aHubThatRefusesTheTokenOpensNothing() async throws {
        let hub = try FakeHub(reply: 0x00)
        let path = hub.path
        let made = HubLoopbackOpener(hub: { .init(socket: path, token: "stale-token") }, address: "10.149.25.1")
        let opener = try #require(made)
        await #expect(throws: LoopbackTunnelFailure.other("Cloud tunnel refused the handshake")) {
            _ = try await opener.openTunnel(host: "localhost", port: 6901)
        }
        #expect(hub.connectRequest.isEmpty, "no CONNECT after a refused token")
    }

    /// An Open Desktop URL names its machine in any case, and only such a URL is one: WebKit
    /// refuses exactly these, since in WebKit the page would be this Mac's own loopback.
    @Test func openDesktopURLsAreRecognizedWhateverTheirCase() throws {
        let url = try #require(RemoteLocalhostService.cloudDesktopURL(machine: "VM-Test"))
        #expect(url.host(percentEncoded: false) == "vm-test.cloud-desktop.localhost")
        #expect(BrowserNavigationGuard.isCloudDesktop(url))
        #expect(BrowserNavigationGuard.isCloudDesktop(try #require(URL(string: "http://VM-TEST.Cloud-Desktop.LOCALHOST:6901/"))))
        #expect(RemoteLocalhostService.desktopMachine(url: url) == "vm-test")
        for other in ["http://localhost:6901/vnc.html", "http://cloud-desktop.localhost.example.com/", "https://example.com/"] {
            #expect(!BrowserNavigationGuard.isCloudDesktop(try #require(URL(string: other))), "\(other)")
        }
    }

    @Test func onlyTheMachinesLocalhostGoesThroughTheHub() async throws {
        let made = HubLoopbackOpener(hub: { Issue.record("dialed the hub"); return .init(socket: "/nonexistent", token: "t") },
                                     address: "10.149.25.1")
        let opener = try #require(made)
        await #expect(throws: LoopbackTunnelFailure.self) { _ = try await opener.openTunnel(host: "example.com", port: 443) }
        let refused = HubLoopbackOpener(hub: { .init(socket: "/nonexistent", token: "t") }, address: "not-an-address")
        #expect(refused == nil)
    }
}
