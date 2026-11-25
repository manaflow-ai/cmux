#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import Foundation
import Testing

/// The phone's last place through the Rust library it links (`LastPlaceStore`,
/// `cmux-mobile-last-place`): saved, read back on a relaunch, and checked against the cached
/// workspaces, with no network.
@Suite struct LastPlaceStoreFFITests {
    private func path() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("last-place-ffi-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("last-place.json").path
    }

    @Test func savedPlaceComesBackOnRelaunch() {
        let path = path()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let store = LastPlaceStore.open(path: path)
        #expect(store.restore(workspaceIds: ["w1"], itemIds: nil) == nil)
        #expect(store.noteLocation(workspaceId: "w1", screen: .chat, itemId: "c1", nowMs: 0) != nil)
        _ = store.noteScroll(workspaceId: "w1", itemId: "c1", anchor: LastPlaceAnchor(row: "m4", offset: 18), nowMs: 10)
        #expect(store.flush())

        let relaunched = LastPlaceStore.open(path: path)
        let place = relaunched.restore(workspaceIds: ["w0", "w1"], itemIds: ["c1"])
        #expect(place?.workspaceId == "w1")
        #expect(place?.screen == .chat)
        #expect(place?.itemId == "c1")
        #expect(place?.selection == "c1")
        #expect(place?.anchor == LastPlaceAnchor(row: "m4", offset: 18))
        // The workspace closed meanwhile: the list.
        #expect(relaunched.restore(workspaceIds: ["w2"], itemIds: nil) == nil)
        // Its tab closed: the workspace, without that tab's scroll.
        let tabGone = relaunched.restore(workspaceIds: ["w1"], itemIds: ["c2"])
        #expect(tabGone?.workspaceId == "w1")
        #expect(tabGone?.itemId == nil)
        #expect(tabGone?.anchor == nil)
    }

    @Test func corruptOrMissingFileIsNoPlace() throws {
        let path = path()
        let dir = (path as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(LastPlaceStore.open(path: path).restore(workspaceIds: ["w1"], itemIds: nil) == nil)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data([0, 255, 7]).write(to: URL(fileURLWithPath: path))
        #expect(LastPlaceStore.open(path: path).restore(workspaceIds: ["w1"], itemIds: nil) == nil)
    }
}
#endif
