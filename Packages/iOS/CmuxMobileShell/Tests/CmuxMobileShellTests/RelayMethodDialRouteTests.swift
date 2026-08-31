import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

/// The relay dial is minted against one exact host device id, and the
/// transport factory refuses a request with no peer binding (an unbound relay
/// session could reach the wrong Mac). A pairing input that carries no device
/// id (an anonymous v2/v3 QR ticket) must therefore skip the synthesized
/// relay route entirely instead of spending a websocket dial that fails at
/// the factory, while a known host id keeps the relay dial after the
/// same-machine loopback lane.
@MainActor
@Suite struct RelayMethodDialRouteTests {
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

    private func relay() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "relay",
            kind: .websocket,
            endpoint: .url("wss://relay.example.test/session"),
            priority: 0
        )
    }

    @Test func knownHostDeviceIDAppendsRelayRouteAfterLoopback() throws {
        let loopback = try loopback()
        let relay = try relay()
        let routes = MobileShellComposite.relayMethodDialRoutes(
            from: [loopback, try tailscale()],
            hostDeviceID: "123e4567-e89b-42d3-a456-426614174004",
            relayRoute: relay
        )

        #expect(routes == [loopback, relay])
    }

    @Test func anonymousTicketDeviceIDExcludesRelayRoute() throws {
        let loopback = try loopback()
        let routes = MobileShellComposite.relayMethodDialRoutes(
            from: [loopback, try tailscale()],
            hostDeviceID: "",
            relayRoute: try relay()
        )

        #expect(routes == [loopback])
    }

    @Test func nilHostDeviceIDExcludesRelayRoute() throws {
        let routes = MobileShellComposite.relayMethodDialRoutes(
            from: [try tailscale()],
            hostDeviceID: nil,
            relayRoute: try relay()
        )

        #expect(routes.isEmpty)
    }

    @Test func whitespaceHostDeviceIDExcludesRelayRoute() throws {
        let loopback = try loopback()
        let routes = MobileShellComposite.relayMethodDialRoutes(
            from: [loopback],
            hostDeviceID: " \n ",
            relayRoute: try relay()
        )

        #expect(routes == [loopback])
    }

    @Test func unresolvedRelayURLFailsClosedToLoopback() throws {
        let loopback = try loopback()
        let routes = MobileShellComposite.relayMethodDialRoutes(
            from: [loopback, try tailscale()],
            hostDeviceID: "123e4567-e89b-42d3-a456-426614174004",
            relayRoute: nil
        )

        #expect(routes == [loopback])
    }

    @Test func relayMethodNeverKeepsNonLoopbackAdvertisedRoutes() throws {
        let relay = try relay()
        let routes = MobileShellComposite.relayMethodDialRoutes(
            from: [try tailscale()],
            hostDeviceID: "123e4567-e89b-42d3-a456-426614174004",
            relayRoute: relay
        )

        #expect(routes == [relay])
    }

    // MARK: Pairing URLs carrying the Mac device id (`d`)

    private func decodedTicket(from url: String) throws -> CmxAttachTicket {
        let parsed = try #require(URL(string: url))
        let components = try #require(
            URLComponents(url: parsed, resolvingAgainstBaseURL: false)
        )
        return try CmxPairingQRCode().decode(components)
    }

    /// A v2 pairing URL that carries the Mac's device id in `d` decodes to a
    /// ticket whose `macDeviceID` binds the relay dial, so the relay method
    /// gains the synthesized relay route on fresh pairing (the exact path
    /// that used to fail fast with `noSupportedRoute` for anonymous URLs).
    @Test func deviceIDBearingV2PairingTicketYieldsRelayRoute() throws {
        let ticket = try decodedTicket(
            from: "cmux-ios://attach?v=2&d=123e4567-e89b-42d3-a456-426614174004"
                + "&r=100.64.0.5:58465"
        )
        #expect(ticket.macDeviceID == "123e4567-e89b-42d3-a456-426614174004")

        let relay = try relay()
        let routes = MobileShellComposite.relayMethodDialRoutes(
            from: ticket.routes,
            hostDeviceID: ticket.macDeviceID,
            relayRoute: relay
        )

        #expect(routes == [relay])
    }

    @Test func deviceIDBearingV3PairingTicketYieldsRelayRoute() throws {
        let ticket = try decodedTicket(
            from: "cmux-ios://attach?v=3&i=\(String(repeating: "c", count: 64))"
                + "&d=123e4567-e89b-42d3-a456-426614174004"
        )
        #expect(ticket.macDeviceID == "123e4567-e89b-42d3-a456-426614174004")

        let relay = try relay()
        let routes = MobileShellComposite.relayMethodDialRoutes(
            from: ticket.routes,
            hostDeviceID: ticket.macDeviceID,
            relayRoute: relay
        )

        #expect(routes == [relay])
    }

    /// An id-less URL from an older Mac keeps the pre-`d` behavior: the
    /// decoded ticket is anonymous and the relay route stays excluded.
    @Test func deviceIDLessV2PairingTicketStillExcludesRelayRoute() throws {
        let ticket = try decodedTicket(
            from: "cmux-ios://attach?v=2&r=100.64.0.5:58465"
        )
        #expect(ticket.macDeviceID == "")

        let routes = MobileShellComposite.relayMethodDialRoutes(
            from: ticket.routes,
            hostDeviceID: ticket.macDeviceID,
            relayRoute: try relay()
        )

        #expect(routes.isEmpty)
    }
}
