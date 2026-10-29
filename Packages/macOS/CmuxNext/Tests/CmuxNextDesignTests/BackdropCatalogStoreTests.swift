import CmuxNextCompat
@testable import CmuxNextDesign
import Foundation
import Testing

/// The wallpaper catalog is built off the main thread, read without rebuilding, and rebuilt after
/// a change to a folder it lists (every-action sweep: rebuilding it on every Settings host-list
/// read stalled the main thread up to 216 ms in AppleWallpapers.pictures).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct BackdropCatalogStoreTests {
    private func folders() throws -> (pictures: URL, images: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backdrops-\(UUID().uuidString)", isDirectory: true)
        let pictures = root.appendingPathComponent("Desktop Pictures", isDirectory: true)
        let images = root.appendingPathComponent("Backgrounds", isDirectory: true)
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        // macOS directory listings may use /private/var while temporaryDirectory uses /var.
        let path = try #require(realpath(root.path, nil))
        defer { free(path) }
        let realRoot = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        return (realRoot.appendingPathComponent("Desktop Pictures"), realRoot.appendingPathComponent("Backgrounds"), realRoot)
    }

    private func waitForBuilds(_ store: BackdropCatalogStore, atLeast count: Int) async {
        // wakeup-allow: bounded wait for the store's own observed build counter
        for await builds in ObservationStream({ store.builds }) where builds >= count { return }
    }

    @Test func theCatalogIsBuiltOnceAndRebuiltOnlyWhenAFolderChanges() async throws {
        let (pictures, images, root) = try folders()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: pictures.appendingPathComponent("Dunes.heic").path, contents: Data([0]))
        let store = BackdropCatalogStore(systemDirectory: pictures, userImages: BackdropUserImages(folder: images),
                                         aerials: root.appendingPathComponent("aerials"), assetFolders: [])
        store.start()
        defer { store.stop() }
        await waitForBuilds(store, atLeast: 1)
        // By the path's end: the catalog lists the folder as the file system names it (/private/var
        // for the /var temporary folder on some hosts, /var on others).
        #expect(store.catalog.appleWallpapers.keys.contains { $0.hasSuffix("/\(pictures.lastPathComponent)/Dunes.heic") })
        // Reads never build.
        for _ in 0..<50 { _ = store.catalog.choices }
        #expect(store.builds == 1)
        // A picture the person adds shows after its folder event.
        FileManager.default.createFile(atPath: images.appendingPathComponent("mine.png").path, contents: Data([0]))
        await waitForBuilds(store, atLeast: 2)
        #expect(store.catalog.choices.contains { $0.id.contains("mine.png") })
    }

    @Test func downloadingAnAerialRefreshesItsPendingState() async throws {
        let (pictures, _, root) = try folders()
        defer { try? FileManager.default.removeItem(at: root) }
        let aerials = root.appendingPathComponent("aerials", isDirectory: true)
        let movies = aerials.appendingPathComponent("4KSDR240FPS", isDirectory: true)
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        try Data(#"{"assets":[{"id":"B2","accessibilityLabel":"Iceland Dusk"}]}"#.utf8)
            .write(to: aerials.appendingPathComponent("entries.json"))
        let downloaded = movies.appendingPathComponent("B2.mov")
        let store = BackdropCatalogStore(systemDirectory: pictures, userImages: nil, aerials: aerials, assetFolders: [])
        store.start()
        defer { store.stop() }
        await waitForBuilds(store, atLeast: 1)
        #expect(store.catalog.pendingVideoPaths.contains(downloaded.path))

        // Only the movie subfolder changes; its parent and entries.json stay untouched.
        try Data().write(to: downloaded)
        // wakeup-allow: await the catalog update caused by this download, never poll.
        for await paths in ObservationStream({ store.catalog.pendingVideoPaths }) where !paths.contains(downloaded.path) { break }
        #expect(store.catalog.choices.contains(.system(path: downloaded.path)))
        #expect(!store.catalog.pendingVideoPaths.contains(downloaded.path))
    }
}
