import CmuxLinkDirect
import CmuxMobileConnect
import CmuxPairing
import Foundation
import Testing

@Suite("route book")
struct RouteBookTests {
    @Test("trusted Macs get Bonjour and saved endpoints under their own key only")
    func joins() async throws {
        let fixture = try await ConnectFixture()
        let state = try #require(await fixture.mirror.state)
        let trusted = await MobileRouteBook.trustedHosts(in: state, lookup: fixture.lookup)
        #expect(trusted.map(\.host) == [ConnectFixture.hostID])
        let macKey = fixture.macDirect.publicKey
        let saved = [
            DirectEndpoint(address: DirectAddress("100.64.0.7")!, hostKey: macKey),
            DirectEndpoint(address: DirectAddress("100.64.0.9")!, hostKey: DirectIdentity().publicKey),
        ]
        let discovered = [
            DirectDiscoveredHost(serviceName: "Studio", domain: "local.", hostID: ConnectFixture.hostID),
            DirectDiscoveredHost(serviceName: "Spoof", domain: "local.", hostID: "host_other"),
        ]
        let routes = MobileRouteBook(trusted: trusted, discovered: discovered, saved: saved).routes()
        let route = try #require(routes.first)
        #expect(routes.count == 1 && route.hostID == ConnectFixture.hostID && route.name == "Studio")
        #expect(route.directEndpoints.map(\.target) == [
            .address(DirectAddress("100.64.0.7")!, port: DirectEndpoint.defaultPort),
            .service(name: "Studio", type: DirectEndpoint.serviceType, domain: "local."),
        ])
        #expect(route.directEndpoints.allSatisfy { $0.hostKey == macKey })
        #expect(route.webrtcHostKey?.x963Representation == fixture.macKey.publicKey.x963Representation)
    }

    @Test("a Mac without endpoints still routes over WebRTC; without a valid key it has no route")
    func noEndpoints() async throws {
        let fixture = try await ConnectFixture()
        let key = try #require(await fixture.lookup.hostKey(for: ConnectFixture.hostID))
        #expect(MobileRouteBook(trusted: [key]).routes().first?.directEndpoints.isEmpty == true)
        var broken = key
        broken.directKey = Data([1, 2, 3])
        #expect(MobileRouteBook(trusted: [broken]).routes().isEmpty)
    }
}
