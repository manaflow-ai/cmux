import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct MobileBrowserPreviewDemandTests {
    @Test func demandRoundTripsThroughRPCObjectAndCodable() throws {
        let demand = MobileBrowserPreviewDemand(
            previewSurfaceIDs: ["preview", "shared", ""],
            fullSurfaceIDs: ["full", "shared"]
        )

        #expect(MobileBrowserPreviewDemand.decodeJSONObject(demand.jsonObject()) == demand)
        let decoded = try JSONDecoder().decode(
            MobileBrowserPreviewDemand.self,
            from: JSONEncoder().encode(demand)
        )
        #expect(decoded == demand)
        #expect(decoded.resolution(for: "preview") == .preview)
        #expect(decoded.resolution(for: "shared") == .full)
        #expect(decoded.resolution(for: "missing") == nil)
    }

    @Test func summaryDropsInactiveDemandAndLetsFullResolutionWin() {
        let summary = MobileBrowserPreviewDemandSummary(demands: [
            MobileBrowserPreviewDemand(previewSurfaceIDs: ["preview", "shared"]),
            MobileBrowserPreviewDemand(fullSurfaceIDs: ["full", "shared"]),
            MobileBrowserPreviewDemand(isActive: false, fullSurfaceIDs: ["inactive"]),
        ])

        #expect(summary.previewSurfaceIDs == ["preview"])
        #expect(summary.fullSurfaceIDs == ["full", "shared"])
        #expect(summary.surfaceIDs == ["preview", "full", "shared"])
        #expect(summary.resolution(for: "shared") == .full)
        #expect(summary.resolution(for: "inactive") == nil)
    }

    @Test func frameRoundTripsJPEGAndMetadata() throws {
        let frame = MobileBrowserPreviewFrame(
            surfaceID: "browser",
            sequence: 4,
            resolution: .full,
            title: "Docs",
            url: "https://example.com/docs",
            imageData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            pixelWidth: 1200,
            pixelHeight: 800
        )
        let payload = try frame.jsonObject()
        let data = try JSONSerialization.data(withJSONObject: payload)
        #expect(try MobileBrowserPreviewFrame.decode(data) == frame)
    }
}
