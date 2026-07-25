import CoreGraphics
import Testing

@testable import CmuxAgentChatUI

@Suite("Inline image preview layout")
struct ChatAttachmentPreviewLayoutTests {
    @Test("known image dimensions reserve their aspect-fit footprint before loading")
    func knownDimensionsReserveAspectFitFootprint() {
        let layout = ChatAttachmentPreviewLayout(pixelWidth: 1_600, pixelHeight: 900)

        let beforeThumbnailLoads = layout.size(maxWidth: 320)
        let afterThumbnailLoads = layout.size(maxWidth: 320)

        #expect(beforeThumbnailLoads == CGSize(width: 320, height: 180))
        #expect(afterThumbnailLoads == beforeThumbnailLoads)
    }

    @Test("missing or invalid dimensions use one deterministic fallback footprint")
    func missingDimensionsUseFallbackFootprint() {
        let missing = ChatAttachmentPreviewLayout(pixelWidth: nil, pixelHeight: nil)
        let zero = ChatAttachmentPreviewLayout(pixelWidth: 0, pixelHeight: 900)
        let negative = ChatAttachmentPreviewLayout(pixelWidth: 1_600, pixelHeight: -1)

        #expect(missing.size(maxWidth: 320) == CGSize(width: 320, height: 240))
        #expect(zero.size(maxWidth: 320) == missing.size(maxWidth: 320))
        #expect(negative.size(maxWidth: 320) == missing.size(maxWidth: 320))
    }

    @Test("ratio-only metadata reserves the final preview aspect")
    func ratioOnlyMetadataReservesFinalPreviewAspect() {
        let layout = ChatAttachmentPreviewLayout(
            pixelWidth: nil,
            pixelHeight: nil,
            aspectRatio: 9.0 / 16.0
        )

        #expect(layout.size(maxWidth: 320) == CGSize(width: 225, height: 400))
    }

    @Test("pixel dimensions override ratio metadata")
    func pixelDimensionsOverrideRatioMetadata() {
        let layout = ChatAttachmentPreviewLayout(
            pixelWidth: 1_600,
            pixelHeight: 900,
            aspectRatio: 1
        )

        #expect(layout.size(maxWidth: 320) == CGSize(width: 320, height: 180))
    }

    @Test("extreme aspect ratios preserve source shape while staying bounded")
    func extremeAspectRatiosPreserveSourceShapeWhileBounded() {
        let tall = ChatAttachmentPreviewLayout(pixelWidth: 1_000, pixelHeight: 5_000)
        let panorama = ChatAttachmentPreviewLayout(pixelWidth: 5_000, pixelHeight: 1_000)

        #expect(tall.size(maxWidth: 320) == CGSize(width: 80, height: 400))
        #expect(panorama.size(maxWidth: 320) == CGSize(width: 320, height: 64))
    }
}
