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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-aerials-\(UUID().uuidString)", isDirectory: true)
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
        let rows = catalog.pageRows.arrayValue ?? []
        let row = { (id: String) in rows.first { $0["id"]?.stringValue == id } }
        #expect(row(have.id)?["video"]?.boolValue == true && row(have.id)?["downloaded"] == nil)
        #expect(row(missing.id)?["video"]?.boolValue == true && row(missing.id)?["downloaded"]?.boolValue == false)

        // Downloaded since: the same choice, now on disk and no longer pending.
        try Data().write(to: movies.appendingPathComponent("B2.mov"))
        #expect(AppleWallpapers(desktopPictures: pictures, aerials: aerials).videos().contains(missing))
        #expect(!AppleWallpapers.isPending(movies.appendingPathComponent("B2.mov").path))
    }
}
