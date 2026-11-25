import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills for msg 40501 ("vault h1 h2 is pinned workspace but it shows gh logo instead of the pin logo"): Home over the
/// Pinned block, with a workspace whose shown tab is a GitHub page and one with its own emoji icon, dark and light.
/// Written under `pinned-tab-icon-gallery/` as `<dark|light>.png`, bundled to `pinned-tab-icon-gallery.tar` for
/// `cmux-ci run --artifact`, so a run before the fix and one after it compare.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAPinnedShownTabIconGalleryTests {
    static func cell(dark: Bool) throws -> CGImage {
        var image: CGImage?
        try PinnedRowShownTabIconTests.atDefaultLook {
            let (list, window) = PinnedRowShownTabIconTests.list(try PinnedRowShownTabIconTests.pageRow())
            defer { window.contentView = nil; window.close() }
            let root = try #require(window.contentView)
            try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            for region in list.blockRegions { region.itemViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded(); $0.layout() } }
            // The rows' own frames, as the other sidebar galleries crop (a fixed band missed them).
            let ids = [PinnedRowShownTabIconTests.home.id, PinnedRowShownTabIconTests.page.id, PinnedRowShownTabIconTests.emoji.id]
            let frames = try ids.map { id in
                let item = try HomePinnedRowAlignmentTests.item(list, id)
                return root.convert(item.bounds, from: item)
            }
            let rows = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
            image = try AAPinnedNoCloseGalleryTests.crop(root, NSRect(x: 0, y: rows.minY, width: root.bounds.width, height: rows.height))
        }
        return try #require(image)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "pinned-tab-icon-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            try AAGroupHeaderDensityGalleryTests.write(try Self.cell(dark: dark), to: out.appending(path: "\(dark ? "dark" : "light").png"))
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "pinned-tab-icon-gallery.tar", "pinned-tab-icon-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
