import Testing
@testable import CmuxBrowser

@Suite
struct MobileBrowserStreamViewportMappingTests {
    @Test
    func preservesPhonePointViewportAndAspect() throws {
        let mapping = try #require(MobileBrowserStreamViewportMapping(
            width: 393,
            height: 852,
            scale: 3
        ))
        #expect(mapping.viewport == BrowserViewport(width: 393, height: 852))
        #expect(Double(mapping.viewport.width) / Double(mapping.viewport.height) == 393.0 / 852.0)
        #expect(mapping.phoneScale == 3)
    }

    @Test
    func clampsEachDimensionToBrowserViewportLimits() throws {
        let mapping = try #require(MobileBrowserStreamViewportMapping(
            width: 0,
            height: 10_000,
            scale: 2
        ))
        #expect(mapping.viewport == BrowserViewport(
            width: BrowserViewport.minimumDimension,
            height: BrowserViewport.maximumDimension
        ))
    }

    @Test(arguments: [0, -1, .infinity, .nan])
    func rejectsInvalidPhoneScale(_ scale: Double) {
        #expect(MobileBrowserStreamViewportMapping(width: 393, height: 852, scale: scale) == nil)
    }
}
