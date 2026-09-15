import CMUXMobileCore
import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileComputerRouteGroupTests {
    @Test func addressFamiliesGroupAndMultiplePeersStaySeparate() throws {
        let routes = try [
            CmxAttachRoute(id: "a4", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.1", port: 1234), groupID: "a"),
            CmxAttachRoute(id: "a6", kind: .tailscale, endpoint: .hostPort(host: "fd7a:115c:a1e0::1", port: 1234), groupID: "a"),
            CmxAttachRoute(id: "b4", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.2", port: 1234), groupID: "b"),
            CmxAttachRoute(id: "b6", kind: .tailscale, endpoint: .hostPort(host: "fd7a:115c:a1e0::2", port: 1234), groupID: "b")
        ]
        let groups = MobileComputerRouteGroup.groups(routes)
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.routes.count == 2 })
    }

    @Test func ambiguousLegacyAddressesAreNotGuessedIntoPairs() throws {
        let routes = try ["100.64.0.1", "100.64.0.2", "fd7a:115c:a1e0::1"].map {
            try CmxAttachRoute(id: $0, kind: .tailscale, endpoint: .hostPort(host: $0, port: 1234))
        }
        #expect(MobileComputerRouteGroup.groups(routes).count == 3)
    }

    @Test func suggestionsRejectNonTailscaleAndDuplicateEndpoints() throws {
        let routes = try ["100.64.0.1", "100.64.0.1", "192.168.1.1"].enumerated().map {
            try CmxAttachRoute(id: "route-\($0.offset)", kind: .tailscale, endpoint: .hostPort(host: $0.element, port: 1234))
        }
        let groups = MobileComputerRouteGroup.suggestions(routes)
        #expect(groups.count == 1)
        #expect(groups.first?.routes.count == 1)
    }
}
