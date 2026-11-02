import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// Apple's aerials (backgrounds plan phase 3b): every aerial macOS lists in idleassetsd's
/// entries.json is a moving wallpaper, downloaded or not. One not on disk yet is named by the file
/// idleassetsd will write and marked not downloaded, so the picker shows it with a cloud and
/// opens System Settings > Wallpaper, where macOS downloads it; then it is a real choice.
struct AppleAerialsCatalogTests {
    @Test func everyListedAerialIsAChoiceAndTheMissingOnesArePending() throws {
        let root = try Self.realFolder("cmux-aerials-\(UUID().uuidString)")
        let pictures = root.appendingPathComponent("Desktop Pictures", isDirectory: true)
        let aerials = root.appendingPathComponent("Customer", isDirectory: true)
        let movies = aerials.appendingPathComponent("4KSDR240FPS", isDirectory: true)
        for folder in [pictures, movies] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data().write(to: movies.appendingPathComponent("A1.mov"))
        try Data(#"{"assets":[{"id":"A1","accessibilityLabel":"Tahoe Morning"},{"id":"B2","accessibilityLabel":"Iceland Dusk"}]}"#.utf8)
            .write(to: aerials.appendingPathComponent("entries.json"))

        let videos = AppleWallpapers(desktopPictures: pictures, aerials: aerials).videos()
        let have = BackdropSelection.system(path: movies.appendingPathComponent("A1.mov").path)
        let missing = BackdropSelection.system(path: movies.appendingPathComponent("B2.mov").path)
        #expect(videos == [have, missing], "the aerials listed are \(videos.map(\.id))")
        #expect(!AppleWallpapers.isPending(movies.appendingPathComponent("A1.mov").path))
        #expect(AppleWallpapers.isPending(movies.appendingPathComponent("B2.mov").path))

        let catalog = BackdropCatalog(systemDirectory: pictures, fileManager: .default, aerials: aerials)
        // Rendering reuses this catalog's metadata and download snapshot without reading disk.
        try FileManager.default.removeItem(at: aerials.appendingPathComponent("entries.json"))
        try FileManager.default.removeItem(at: movies.appendingPathComponent("A1.mov"))
        let rows = catalog.pageRows.arrayValue ?? []
        let row = { (id: String) in rows.first { $0["id"]?.stringValue == id } }
        #expect(row(have.id)?["title"]?.stringValue == "Tahoe Morning")
        #expect(row(missing.id)?["title"]?.stringValue == "Iceland Dusk")
        #expect(row(missing.id)?["attribution"]?.stringValue?.contains("Iceland Dusk") == true)
        #expect(row(have.id)?["video"]?.boolValue == true && row(have.id)?["downloaded"] == nil)
        #expect(row(missing.id)?["video"]?.boolValue == true && row(missing.id)?["downloaded"]?.boolValue == false)

        // Downloaded since: the same choice, now on disk and no longer pending.
        try Data().write(to: movies.appendingPathComponent("B2.mov"))
        #expect(AppleWallpapers(desktopPictures: pictures, aerials: aerials).videos().contains(missing))
        #expect(!AppleWallpapers.isPending(movies.appendingPathComponent("B2.mov").path))
    }

    /// The review's case (#21784): an id from entries.json names a file, so one that is not
    /// letters, digits and dashes is dropped; an asset without an id or a name drops only itself.
    @Test func unsafeOrBrokenAssetsAreDroppedOneByOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-aerials-\(UUID().uuidString)", isDirectory: true)
        let aerials = root.appendingPathComponent("Customer", isDirectory: true)
        try FileManager.default.createDirectory(at: aerials, withIntermediateDirectories: true)
        try Data(#"{"assets":[{"id":"../../../etc/hosts","accessibilityLabel":"Escape"},{"id":"a/b","accessibilityLabel":"Slash"},{"accessibilityLabel":"No id"},{"id":"C3"},{"id":"D4-E5","accessibilityLabel":"Iceland Dusk"},"junk"]}"#.utf8)
            .write(to: aerials.appendingPathComponent("entries.json"))
        let wallpapers = AppleWallpapers(desktopPictures: root.appendingPathComponent("Desktop Pictures"), aerials: aerials)
        #expect(wallpapers.aerialNames() == ["D4-E5": "Iceland Dusk"])
        let videos = wallpapers.videos()
        #expect(videos.count == 1)
        guard case .system(let path) = videos.first else {
            Issue.record("no aerial listed")
            return
        }
        #expect(path.hasPrefix(aerials.path + "/"), "an aerial path left the Customer folder: \(path)")
    }

    /// A new folder under the temporary directory, by its real path: the listing reads
    /// /private/var/folders, which a path built on temporaryDirectory (/var/folders) never equals.
    private static func realFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let real = realpath(url.path, nil) else { return url }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }
}

@Test func wallpaperPageRowsAreMemoizedUntilTheCatalogChanges() {
    var cache = BackdropCatalogPageRowsCache()
    let catalog = BackdropCatalog(bundledOnly: ())

    for _ in 0..<100 { _ = cache.rows(for: catalog) }

    #expect(cache.rows(for: catalog) == catalog.pageRows)
    #expect(cache.builds == 1)
}
