import CmuxNextRemoteLocalhost
import CmuxNextRemoteLocalhostService
import Foundation
import Network
import Testing

/// A Cloud workspace's `localhost:3000` tab that loaded while the machine's link was down showed
/// "not connected" until the person reloaded it by hand, even after the link was back (#25595).
/// The proxy now remembers which addresses it answered that way, per machine listener, so the app
/// loads those pages again when the machine connects.
struct RemoteLocalhostStrandedTests {
    private nonisolated struct Opener: LoopbackTunnelOpening {
        let failure: LoopbackTunnelFailure
        func openTunnel(host: String, port: UInt16) async throws(LoopbackTunnelFailure) -> any LoopbackTunnel {
            throw failure
        }
    }

    /// Sends one plain-HTTP proxy request to `port` (this process is a trusted peer) and returns the
    /// response's status line.
    private func get(_ target: String, through port: UInt16) async throws -> String {
        let connection = NWConnection(host: .ipv4(.loopback), port: try #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
        defer { connection.cancel() }
        let queue = DispatchQueue(label: "stranded-test")
        let request = Data("GET \(target) HTTP/1.1\r\nHost: \(URL(string: target)?.host() ?? "")\r\nConnection: close\r\n\r\n".utf8)
        connection.start(queue: queue)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: request, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        var response = Data()
        while true {
            let (chunk, complete): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, complete)) }
                }
            }
            if let chunk { response.append(chunk) }
            if complete || response.range(of: Data("\r\n".utf8)) != nil { break }
        }
        return String(decoding: response, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
    }

    @Test func aPageThatFoundTheMachineNotConnectedIsRememberedOnce() async throws {
        let proxy = RemoteLocalhostProxy()
        defer { proxy.stop() }
        let port = try await proxy.listen(for: "machine", route: .init(machineName: "vm", opener: Opener(failure: .unavailable("link down"))))
        let status = try await get("http://localhost:3000/app", through: port)
        #expect(status.hasPrefix("HTTP/1.1 502"))
        #expect(proxy.takeStranded(listenerPort: port) == ["localhost:3000"])
        // Taken once: the next reconnect reloads nothing unless it failed again.
        #expect(proxy.takeStranded(listenerPort: port).isEmpty)
    }

    @Test func aPortThatRefusedIsNotStranded() async throws {
        let proxy = RemoteLocalhostProxy()
        defer { proxy.stop() }
        let port = try await proxy.listen(for: "machine", route: .init(machineName: "vm", opener: Opener(failure: .refused)))
        _ = try await get("http://localhost:3000/", through: port)
        // Nothing listened on the machine: a reconnect would not change the answer.
        #expect(proxy.takeStranded(listenerPort: port).isEmpty)
    }

    @Test(arguments: [
        ("http://localhost:3000/a?b", true),
        ("http://LOCALHOST:3000/", true),
        ("http://localhost/", false),
        ("http://localhost:3001/", false),
        ("http://127.0.0.1:8080/", true),
        ("http://[::1]:5173/", true),
    ])
    func aPageMatchesTheAddressItsRequestWentTo(url: String, matches: Bool) throws {
        let addresses: Set<String> = [
            RemoteLocalhostProxy.address(host: "localhost", port: 3000),
            RemoteLocalhostProxy.address(host: "127.0.0.1", port: 8080),
            RemoteLocalhostProxy.address(host: "::1", port: 5173),
        ]
        #expect(StrandedPageReload.matches(try #require(URL(string: url)), addresses: addresses) == matches)
    }
}
