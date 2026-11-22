@testable import CmuxNextDesign
import Foundation
import Testing

/// Use My Screen Saver (Leo, 2026-10-20: "use my screensaver stuff ... stick it wayyy up there"):
/// the aerial the wallpaper store's index names for the idle screen is one of the moving
/// wallpapers, found by its asset id.
@Suite struct AppleWallpapersScreenSaverTests {
    private struct Fixture {
        let root: URL
        let wallpapers: AppleWallpapers
        let movies: URL
        let index: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("screen-saver-\(UUID().uuidString)", isDirectory: true)
            let aerials = root.appendingPathComponent("aerials", isDirectory: true)
            movies = aerials.appendingPathComponent("4KSDR240FPS", isDirectory: true)
            try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Desktop Pictures"), withIntermediateDirectories: true)
            try Data(#"{"assets":[{"id":"A1-B2","accessibilityLabel":"Iceland Dusk"},{"id":"C3","accessibilityLabel":"Tahoe"}]}"#.utf8)
                .write(to: aerials.appendingPathComponent("entries.json"))
            wallpapers = AppleWallpapers(desktopPictures: root.appendingPathComponent("Desktop Pictures"), aerials: aerials)
            index = root.appendingPathComponent("Index.plist")
        }

        /// An index whose `AllSpacesAndDisplays` holds `scope` under `key` (Idle or Linked), the
        /// aerial id in the choice's own nested property list, as macOS writes it.
        func writeIndex(key: String, assetID: String, provider: String = "com.apple.wallpaper.choice.aerials") throws {
            let configuration = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
            let choice: [String: Any] = ["Provider": provider, "Configuration": configuration, "Files": [Any]()]
            let scope: [String: Any] = [key: ["Content": ["Choices": [choice], "Shuffle": "$null"]], "Type": "idle"]
            let data = try PropertyListSerialization.data(fromPropertyList: ["AllSpacesAndDisplays": scope], format: .binary, options: 0)
            try data.write(to: index)
        }
    }

    @Test func theIdleAerialIsItsMovingWallpaper() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data().write(to: fixture.movies.appendingPathComponent("A1-B2.mov"))
        try fixture.writeIndex(key: "Idle", assetID: "A1-B2")
        let saver = try #require(await fixture.wallpapers.screenSaver(index: fixture.index))
        guard case .system(let path) = saver else { Issue.record("not a system wallpaper: \(saver)"); return }
        #expect(URL(fileURLWithPath: path).lastPathComponent == "A1-B2.mov")
    }

    @Test func aScreenSaverLinkedToTheWallpaperIsFoundEvenBeforeItIsDownloaded() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeIndex(key: "Linked", assetID: "C3")
        let saver = try #require(await fixture.wallpapers.screenSaver(index: fixture.index))
        // Listed by entries.json but not on disk: the picker shows it with a cloud.
        #expect(saver.id.hasSuffix("/C3.mov"))
        #expect(AppleWallpapers.isPending(saver.id.replacingOccurrences(of: "system:", with: "")))
    }

    @Test func aScreenSaverThatIsNotAnAerialIsNone() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writeIndex(key: "Idle", assetID: "Flurry", provider: "com.apple.NeptuneOneExtension")
        #expect(await fixture.wallpapers.screenSaver(index: fixture.index) == nil)
        // No index at all (the store not written yet).
        #expect(await fixture.wallpapers.screenSaver(index: fixture.root.appendingPathComponent("missing.plist")) == nil)
    }
}
