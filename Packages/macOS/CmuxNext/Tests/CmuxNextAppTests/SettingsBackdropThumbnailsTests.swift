import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextPages
import Foundation
import Testing

/// The Settings page's wallpaper tiles load `backdrop/<id>` with the id percent encoded twice
/// (`encodeURIComponent` of `encodeURIComponent`): the scheme router decodes the path before
/// splitting it, so a macOS wallpaper's id, `system:/System/Library/…`, stays one component.
@MainActor
struct SettingsBackdropThumbnailsTests {
    @Test func aSystemWallpaperTileGetsItsThumbnail() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("backdrop-thumbnails-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = folder.appendingPathComponent("Blue Hour.png")
        let image = NSImage(size: NSSize(width: 32, height: 20), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        try #require(SettingsBackdropThumbnails.thumbnail(image)).write(to: picture)
        let selection = BackdropSelection.system(path: picture.path)
        let source = SettingsBackdropThumbnails(choices: [selection], userImages: nil)

        // As the page spells it: `encodeURIComponent` twice.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        let once = try #require(selection.id.addingPercentEncoding(withAllowedCharacters: allowed))
        let id = try #require(once.addingPercentEncoding(withAllowedCharacters: allowed))
        let url = try #require(URL(string: "cmux-page://cmux.settings/\(SettingsBackdropThumbnails.prefix)/\(id)"))
        guard case let .dynamic(request) = PageSchemeHandler.route(for: url, page: .settings, root: folder) else {
            Issue.record("backdrop/<id> is not a dynamic resource")
            return
        }
        let png = try #require(await source.resource(for: request))
        #expect(png.mimeType == "image/png")
        #expect(png.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }
}
