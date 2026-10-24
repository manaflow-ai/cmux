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
        return (pictures, images, root)
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
}
