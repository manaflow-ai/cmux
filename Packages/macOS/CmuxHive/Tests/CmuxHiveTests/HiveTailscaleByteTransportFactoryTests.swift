import CMUXMobileCore
import CmuxMobileTransport
import Testing
@testable import CmuxHive

/// The viewer's tailscale transport factory must only dial hosts that are
/// verifiably inside the tailnet address space.
struct HiveTailscaleByteTransportFactoryTests {
    private func route(kind: CmxAttachTransportKind, host: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "r", kind: kind, endpoint: .hostPort(host: host, port: 52422))
    }

    @Test func buildsTransportsForTailnetHostsOnly() throws {
        let factory = HiveTailscaleByteTransportFactory()
        #expect(throws: Never.self) {
            _ = try factory.makeTransport(for: try route(kind: .tailscale, host: "100.65.181.35"))
        }
        #expect(throws: Never.self) {
            _ = try factory.makeTransport(for: try route(kind: .tailscale, host: "fd7a:115c:a1e0::f536:b524"))
        }
        #expect(throws: Never.self) {
            _ = try factory.makeTransport(for: try route(kind: .tailscale, host: "mini.tail1234.ts.net"))
        }
        // A LAN or loopback host smuggled under the tailscale kind fails
        // exactly like the shared fail-closed factory.
        #expect(throws: (any Error).self) {
            _ = try factory.makeTransport(for: try route(kind: .tailscale, host: "192.168.86.21"))
        }
        #expect(throws: (any Error).self) {
            _ = try factory.makeTransport(for: try route(kind: .debugLoopback, host: "127.0.0.1"))
        }
    }
}
