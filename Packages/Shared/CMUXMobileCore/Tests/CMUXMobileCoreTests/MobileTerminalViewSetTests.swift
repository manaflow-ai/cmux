import Foundation
import Testing
@testable import CMUXMobileCore

@Test func viewSetParamsRoundTripThroughJSON() throws {
    let viewSet = MobileTerminalViewSet(surfaceIDs: [UUID(), UUID()])
    let wire = try JSONSerialization.jsonObject(
        with: JSONSerialization.data(withJSONObject: viewSet.params)
    ) as? [String: Any]
    let params = try #require(wire)
    #expect(MobileTerminalViewSet(params: params) == viewSet)
    #expect(MobileTerminalViewSet(params: ["surface_ids": [String]()])?.surfaceIDs == [])
}

@Test func viewSetRejectsMalformedOrOversizedDeclarations() {
    #expect(MobileTerminalViewSet(params: [:]) == nil)
    #expect(MobileTerminalViewSet(params: ["surface_ids": ["not-a-terminal"]]) == nil)
    let tooMany = (0...MobileTerminalViewSet.maximumSurfaceCount).map { _ in UUID().uuidString }
    #expect(MobileTerminalViewSet(params: ["surface_ids": tooMany]) == nil)
}
