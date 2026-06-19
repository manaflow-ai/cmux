import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

/// A restored/published Mac advertises both a `debug_loopback` route
/// (`127.0.0.1`, priority 0) and a `tailscale` route. On a physical phone the
/// loopback route names the phone itself and can never reach the Mac, so route
/// selection must prefer the real route there — otherwise tapping a saved Mac
/// dials the phone's own loopback and silently fails to connect.
@MainActor
@Suite struct ReconnectRouteSelectionTests {
    private func loopback(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: 0
        )
    }

    private func tailscale(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: port),
            priority: 10
        )
    }

    @Test func physicalDevicePrefersRealRouteOverLowerPriorityLoopback() throws {
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "100.82.214.112") // tailscale, not the phone's 127.0.0.1
    }

    @Test func physicalDeviceFallsBackToLoopbackWhenItIsTheOnlyRoute() throws {
        // The on-device XCUITest mock host serves a real listener on 127.0.0.1.
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "127.0.0.1")
    }

    @Test func simulatorKeepsLoopbackPriorityOrder() throws {
        // On the simulator 127.0.0.1 IS the host Mac, so priority order stands.
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: false
        )
        #expect(pick?.0 == "127.0.0.1")
    }
}
