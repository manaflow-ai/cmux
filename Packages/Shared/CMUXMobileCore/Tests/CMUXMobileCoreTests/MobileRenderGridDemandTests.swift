import Foundation
import Testing
@testable import CMUXMobileCore

@Test func renderGridDemandWireRoundTripNormalizesSurfaceSets() throws {
    let demand = MobileRenderGridDemand(
        isActive: true,
        focusedSurfaceIDs: ["focused", ""],
        previewSurfaceIDs: ["preview-b", "preview-a", "preview-a"]
    )

    let decoded = try #require(MobileRenderGridDemand.decodeJSONObject(demand.jsonObject()))
    #expect(decoded == demand)
    #expect(decoded.surfaceIDs == ["focused", "preview-a", "preview-b"])
    #expect(demand.jsonObject()["preview_surface_ids"] as? [String] == ["preview-a", "preview-b"])
}

@Test func renderGridDemandSummaryAccountsForSubscribeAndUnsubscribePerSurface() {
    var streams: [String: MobileRenderGridDemandScope] = [
        "hub": .scoped(MobileRenderGridDemand(previewSurfaceIDs: ["a", "b"])),
        "mounted": .scoped(MobileRenderGridDemand(focusedSurfaceIDs: ["b"])),
    ]

    var summary = MobileRenderGridDemandSummary(scopes: streams.values)
    #expect(summary.focusedSurfaceIDs == ["b"])
    #expect(summary.previewSurfaceIDs == ["a"])
    #expect(summary.contains(surfaceID: "a"))

    streams.removeValue(forKey: "hub")
    summary = MobileRenderGridDemandSummary(scopes: streams.values)
    #expect(summary.surfaceIDs == ["b"])
    #expect(!summary.contains(surfaceID: "a"))

    streams.removeAll()
    #expect(!MobileRenderGridDemandSummary(scopes: streams.values).hasDemand)
}

@Test func inactiveRenderGridDemandRetainsNoSurfaceCost() {
    let summary = MobileRenderGridDemandSummary(scopes: [
        .scoped(MobileRenderGridDemand(
            isActive: false,
            focusedSurfaceIDs: ["focused"],
            previewSurfaceIDs: ["preview"]
        )),
    ])

    #expect(!summary.hasDemand)
    #expect(summary.surfaceIDs.isEmpty)
}
