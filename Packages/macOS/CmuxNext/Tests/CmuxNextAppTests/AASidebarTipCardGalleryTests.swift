import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of the sidebar's "Did you know?" tip card for Lawrence 2026-11-19 (msg 40504, "need more padding here"):
/// the Command Palette tip at every density (``DensityPreset``), dark and light, in a 220 pt sidebar's card width.
/// Written under `sidebar-tip-card-gallery/` (`<density>-<dark|light>.png` and `all.png`: a row per density, dark on the
/// left), bundled to `sidebar-tip-card-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarTipCardGalleryTests {
    nonisolated static var needsDisplay: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_TEST_REQUIRE_GUI"] == "1" || env["CMUX_CI_DISPLAY_ROUTED"] == "1"
    }

    @Test(.enabled(if: needsDisplay))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-tip-card-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let width = SidebarBottomCardSlot.cardWidth(in: 220)
        var rows: [[CGImage]] = []
        for density in DensityPreset.allCases {
            var row: [CGImage] = []
            for dark in [true, false] {
                let image = try DensityTokens.$scoped.withValue(density.tokens) {
                    try AASidebarNoticeCardGalleryTests.notice(SidebarTipCardPaddingTests.tip, width: width, placement: .above, dark: dark)
                }
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(density.rawValue)-\(dark ? "dark" : "light").png"))
                row.append(image)
            }
            rows.append(row)
        }
        let gap = 16
        let cellW = rows.flatMap { $0 }.map(\.width).max() ?? 1
        let heights = rows.map { $0.map(\.height).max() ?? 0 }
        let ctx = try #require(CGContext(data: nil, width: 2 * cellW + 3 * gap, height: heights.reduce(0, +) + (heights.count + 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        var top = ctx.height - gap
        for (row, height) in zip(rows, heights) {
            top -= height
            for (column, image) in row.enumerated() {
                ctx.draw(image, in: CGRect(x: gap + column * (cellW + gap), y: top + height - image.height, width: image.width, height: image.height))
            }
            top -= gap
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-tip-card-gallery.tar", "sidebar-tip-card-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
