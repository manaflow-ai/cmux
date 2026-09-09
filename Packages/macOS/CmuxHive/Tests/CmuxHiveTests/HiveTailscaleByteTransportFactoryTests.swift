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

    private func admissionRequest(kind: CmxAttachTransportKind, host: String) throws -> CmxByteTransportRequest {
        CmxByteTransportRequest(
            route: try route(kind: kind, host: host),
            expectedPeerDeviceID: "mac-b", authorizationMode: .transportAdmission
        )
    }

    @Test func buildsTransportsForTailnetHostsOnly() throws {
        let factory = HiveTailscaleByteTransportFactory()
        #expect(throws: Never.self) {
            _ = try factory.makeTransport(for: try admissionRequest(kind: .tailscale, host: "100.65.181.35"))
        }
        #expect(throws: Never.self) {
            _ = try factory.makeTransport(for: try admissionRequest(kind: .tailscale, host: "fd7a:115c:a1e0::f536:b524"))
        }
        #expect(throws: Never.self) {
            _ = try factory.makeTransport(for: try admissionRequest(kind: .tailscale, host: "mini.tail1234.ts.net"))
        }
        // A LAN or loopback host smuggled under the tailscale kind fails
        // exactly like the shared fail-closed factory.
        #expect(throws: (any Error).self) {
            _ = try factory.makeTransport(for: try admissionRequest(kind: .tailscale, host: "192.168.86.21"))
        }
        #expect(throws: (any Error).self) {
            _ = try factory.makeTransport(for: try admissionRequest(kind: .debugLoopback, host: "127.0.0.1"))
        }
    }

    @Test(arguments: ["100.65.181.35", "fd7a:115c:a1e0::f536:b524", "mini.tail1234.ts.net"])
    func routeOnlyCallsCannotBypassAdmission(host: String) throws {
        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try HiveTailscaleByteTransportFactory().makeTransport(
                for: try route(kind: .tailscale, host: host)
            )
        }
    }

    @Test func rejectsStackBearerRequestsUntilPeerAdmissionIsProven() throws {
        let route = try route(kind: .tailscale, host: "100.65.181.35")
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-b",
            authorizationMode: .stackBearer
        )
        #expect(throws: (any Error).self) {
            _ = try HiveTailscaleByteTransportFactory().makeTransport(for: request)
        }
    }
}
