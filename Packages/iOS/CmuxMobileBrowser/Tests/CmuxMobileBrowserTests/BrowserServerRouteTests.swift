import Foundation
import Testing

@testable import CmuxMobileBrowser

/// Loopback addresses bypass the proxy, so an SSH route must mirror their
/// port; everything else rides the proxy untouched.
@MainActor
@Suite struct BrowserServerRouteTests {
    @Test func loopbackAddressesYieldTheirPort() {
        let cases: [(String, Int?)] = [
            ("http://localhost:3000/a", 3000),
            ("http://LOCALHOST:3000", 3000),
            ("http://127.0.0.1:8080", 8080),
            ("http://127.9.8.7:81", 81),
            ("http://[::1]:5173/", 5173),
            ("http://0.0.0.0:8000", 8000),
            ("https://localhost/", 443),
            ("http://localhost/", 80),
            ("http://app.localhost:3000", nil),
            ("https://example.com", nil),
            ("http://192.168.1.10:3000", nil),
            ("http://128.0.0.1", nil),
            ("file:///tmp/x", nil),
        ]
        for (string, port) in cases {
            #expect(BrowserServerRoute.loopbackPort(of: URL(string: string)!) == port, "\(string)")
        }
    }

    @Test func routeIsSharedPerComputerAndReadiesLoopbackPortsOnce() async throws {
        var asked: [Int?] = []
        let id = "test-\(UUID().uuidString)"
        let route = BrowserServerRoute.route(id: id) { port in
            asked.append(port)
            return 41_000
        }
        #expect(BrowserServerRoute.route(id: id) { _ in 0 } === route)
        let page = URL(string: "http://localhost:3000/")!
        #expect(route.needsReady(for: page))
        #expect(!route.needsReady(for: URL(string: "https://example.com/")!))
        // The newest prepare wins; ready records the mirrored port.
        _ = BrowserServerRoute.route(id: id) { port in
            asked.append(port)
            return 41_000
        }
        try await route.ready(for: page)
        #expect(asked == [3000])
        #expect(!route.needsReady(for: page))
        #expect(route.dataStore.proxyConfigurations.count == 1)
    }
}
