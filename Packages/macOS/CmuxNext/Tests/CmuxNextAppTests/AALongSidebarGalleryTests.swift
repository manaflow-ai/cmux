import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-10: "where's our infinite scroll". The 2,000-workspace sidebar, drawn offscreen at its top, its middle
/// and its bottom (the long-running window shape of `SidebarScrollBench`: groups of eight, agent rows with status lines,
/// unread counts and spinners), and a Pinned block of 2,000 items scrolled into its middle. Each still's caption counts
/// the views the sidebar holds, which stay a screenful at every position (`SidebarLongListScaleTests` is the check).
/// Written as PNGs under `long-sidebar-gallery/` in the package and bundled to `long-sidebar-gallery.tar` for
/// `cmux-ci run --artifact`. Runs only with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AALongSidebarGalleryTests {
    static let count = 2_000

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        _ = NSApplication.shared
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "long-sidebar-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var captions: [String] = []

        for dark in [true, false] {
            let bench = SidebarScrollBench(count: Self.count, height: 720)
            defer { bench.close() }
            try AAPinnedNoCloseGalleryTests.theme(bench.sidebar, bench.window, dark: dark)
            for (name, fraction) in [("top", 0.0), ("middle", 0.5), ("bottom", 1.0)] {
                _ = bench.frame(to: (bench.maxY * fraction).rounded())
                let image = try AAPinnedNoCloseGalleryTests.crop(bench.sidebar, bench.sidebar.bounds)
                let file = "workspaces-\(Self.count)-\(name)-\(dark ? "dark" : "light").png"
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: file))
                captions.append("\(file): row_views=\(bench.rowViewsInList) views=\(SidebarLongListScaleTests.viewCount(bench.sidebar))")
            }
        }

        let pinned = try PinnedBlockFixture(items: Self.count, height: 720)
        defer { pinned.close() }
        try AAPinnedNoCloseGalleryTests.theme(pinned.scrollView, pinned.window, dark: true)
        pinned.scroll(to: CGFloat(Self.count / 2) * SidebarRegionMetrics.standard.rowHeight)
        let image = try AAPinnedNoCloseGalleryTests.crop(pinned.scrollView, pinned.scrollView.bounds)
        try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "pinned-\(Self.count)-middle-dark.png"))
        captions.append("pinned-\(Self.count)-middle-dark.png: item_views=\(pinned.region?.itemViews.count ?? 0)")

        try captions.joined(separator: "\n").write(to: out.appending(path: "captions.txt"), atomically: true, encoding: .utf8)
        print(captions.map { "LONG-SIDEBAR-GALLERY " + $0 }.joined(separator: "\n"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "long-sidebar-gallery.tar", "long-sidebar-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
