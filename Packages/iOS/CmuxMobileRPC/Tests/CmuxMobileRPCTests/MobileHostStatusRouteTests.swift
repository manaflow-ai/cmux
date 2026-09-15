import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileHostStatusRouteTests {
    @Test func authenticatedStatusDecodesGroupedRoutesAndIgnoresMalformedRoutes() throws {
        let json = """
        {"mac_device_id":"mac-a","mac_instance_tag":"stable","routes":[
          {"id":"iroh","kind":"iroh","endpoint":{"type":"peer","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
          {"id":"tailscale","kind":"tailscale","groupID":"peer-a","endpoint":{"type":"host_port","host":"100.64.0.2","port":49152}}
        ]}
        """.data(using: .utf8)!
        let response = try MobileHostStatusResponse.decode(json)
        #expect(response.routes.count == 2)
        #expect(response.routes.last?.groupID == "peer-a")
        #expect(response.routes.last?.kind == .tailscale)
    }

    @Test func missingRoutesRemainCompatibleWithOlderMacs() throws {
        let response = try MobileHostStatusResponse.decode(Data("{}".utf8))
        #expect(response.routes.isEmpty)
    }
}
