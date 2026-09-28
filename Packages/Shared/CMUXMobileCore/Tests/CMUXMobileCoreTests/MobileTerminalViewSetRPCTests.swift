import Foundation
import Testing
@testable import CMUXMobileCore

@Test func viewSetParamsRoundTripThroughJSON() throws {
    let ids: Set<String> = [UUID().uuidString, UUID().uuidString.lowercased()]
    let wire = try JSONSerialization.jsonObject(
        with: JSONSerialization.data(withJSONObject: MobileTerminalViewSetRPC.params(surfaceIDs: ids))
    ) as? [String: Any]
    let params = try #require(wire)
    let parsed = try #require(MobileTerminalViewSetRPC.surfaceIDs(from: params))
    #expect(parsed == Set(ids.compactMap(UUID.init(uuidString:))))
    #expect(MobileTerminalViewSetRPC.surfaceIDs(from: ["surface_ids": [String]()]) == [])
}

@Test func viewSetRejectsMalformedOrOversizedDeclarations() {
    #expect(MobileTerminalViewSetRPC.surfaceIDs(from: [:]) == nil)
    #expect(MobileTerminalViewSetRPC.surfaceIDs(from: ["surface_ids": ["not-a-terminal"]]) == nil)
    let tooMany = (0...MobileTerminalViewSetRPC.maximumSurfaceCount).map { _ in UUID().uuidString }
    #expect(MobileTerminalViewSetRPC.surfaceIDs(from: ["surface_ids": tooMany]) == nil)
}
