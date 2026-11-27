import AppKit
@testable import CmuxNextApp
@testable import CmuxNextPages
import CmuxNextSettings
import CmuxNextSettingsWindow
import Foundation
import Testing

/// The Settings page draws a stored image or SVG icon (cx-qno.2.3): its host lists carry each
/// space's icon, and `cmux-page://cmux.settings/icon/<ref>` answers the host's PNG of the asset,
/// decoded as the sidebar draws it, so the page never loads SVG markup itself.
@MainActor
struct SettingsIconAssetsTests {
    static let icon = "svg:sha256-" + String(repeating: "b", count: 64)
    static let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z" fill="#22d"></path></svg>"##.utf8)

    @Test func theSettingsPageServesAStoredIconAsAPNG() async throws {
        #expect(PageDescriptor.settings.dynamicPrefixes.contains(SettingsIconAssets.prefix))
        let source = SettingsBackdropThumbnails(choices: [], userImages: nil, iconPNG: { icon in
            icon == Self.icon ? await SettingsIconAssets.encoded(Self.svg, mediaType: "image/svg+xml") : nil
        })
        let ref = try #require(Self.icon.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let url = try #require(URL(string: "cmux-page://cmux.settings/icon/\(ref)"))
        let png = try #require(await source.resource(for: PageResourceRequest(prefix: SettingsIconAssets.prefix, path: [ref], url: url)))
        #expect(png.mimeType == "image/png")
        #expect(png.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(await SettingsIconAssets.png("star.fill", owner: nil) == nil, "only a stored asset is served")
    }

    @Test func aSpaceRowCarriesItsIcon() {
        let row = SettingsListRow.space(id: "r1", title: "Work", icon: Self.icon)
        #expect(SettingsWindowService.listRow(row)["icon"] == .string(Self.icon))
    }
}
