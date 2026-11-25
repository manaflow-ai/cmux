@testable import CmuxNextApps
import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextApp

/// The React App Store's native side (plans/cmux-next/apps-web-DESIGN.md): the `glyph/` icon
/// resource and the routes `appStore.show` opens.
@MainActor @Suite struct AppsPageBridgeTests {
    @Test func theDescriptorServesGlyphs() {
        #expect(PageDescriptor.apps.dynamicPrefixes.contains(AppsGlyphResource.prefix))
        #expect(!PageDescriptor.apps.admits("cmux.app.features.list"), "the store has no Features tab (extensibility-DESIGN.md)")
    }

    @Test func aGlyphIsAPNGOfThePacksDrawingAndNeverASystemSymbol() async throws {
        let glyphs = AppsGlyphResource()
        func request(_ prefix: String, _ name: String) -> PageResourceRequest {
            PageResourceRequest(prefix: prefix, path: [name], url: URL(string: "cmux-page://cmux.apps/\(prefix)/\(name)")!)
        }
        let cloud = try #require(await glyphs.resource(for: request(AppsGlyphResource.prefix, "cloud")))
        #expect(cloud.mimeType == "image/png")
        #expect(cloud.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(await glyphs.resource(for: request(AppsGlyphResource.prefix, "not.a.symbol.anywhere")) == nil)
        #expect(await glyphs.resource(for: request(AppsGlyphResource.prefix, "applelogo")) == nil,
                "an SF Symbol the pack does not draw is never served (Q5)")
        #expect(await glyphs.resource(for: request("other", "cloud")) == nil)
    }

    @Test func showStoreRoutes() {
        #expect(AppsService.storeRoute(appID: nil, tab: nil) == "#/discover")
        #expect(AppsService.storeRoute(appID: nil, tab: .installed) == "#/installed")
        #expect(AppsService.storeRoute(appID: "cmux/cloud", tab: .installed) == "#/discover?app=cmux/cloud")
        #expect(AppStoreTab(argument: " Installed ") == .installed)
        #expect(AppStoreTab(argument: "features") == nil, "features are Settings now; the store opens as it is")
    }
}
