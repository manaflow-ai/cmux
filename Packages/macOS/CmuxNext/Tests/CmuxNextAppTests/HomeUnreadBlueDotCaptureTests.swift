import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing
import UniformTypeIdentifiers

/// The picture for `HomeUnreadBlueDotTests` (Lawrence 2026-10-23: "home unread indicator should just
/// be blue dot instead"): the top of a 260 pt sidebar, its Home row with three unread conversations
/// over an unread and a read workspace row, at each `sidebar.density` (columns) in dark then light
/// (rows), in `.build/home-blue-dot.png` (a fleet step returns it with `--artifact`). It checks only
/// that each drew; `HomeUnreadBlueDotTests` checks the dot.
@MainActor @Suite(.serialized)
struct HomeUnreadBlueDotCaptureTests {
    private func capture(_ density: SidebarDensity, dark: Bool) -> CGImage? {
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        let h = HomeUnreadBlueDotTests.Harness(width: 260, dark: dark)
        defer { h.window.close() }
        guard let rep = h.render(), let image = rep.cgImage else { return nil }
        // The top 110 pt: Home and the two workspace rows.
        let scale = CGFloat(rep.pixelsWide) / 260
        return image.cropping(to: CGRect(x: 0, y: 0, width: Int(260 * scale), height: Int(110 * scale)))
    }

    @Test func homeDotBesideAWorkspaceDotAtEveryDensity() throws {
        let gap = 12
        var grid: [[CGImage]] = []
        for dark in [true, false] {
            grid.append(try SidebarDensity.allCases.map { try #require(capture($0, dark: dark), "\($0) \(dark ? "dark" : "light") drew nothing") })
        }
        let width = grid.map { $0.map(\.width).reduce(0, +) + gap * ($0.count - 1) }.max() ?? 0
        let height = grid.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + gap * (grid.count - 1)
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var y = height
        for row in grid {
            let rowHeight = row.map(\.height).max() ?? 0
            y -= rowHeight
            var x = 0
            for image in row {
                ctx.draw(image, in: CGRect(x: x, y: y + rowHeight - image.height, width: image.width, height: image.height))
                x += image.width + gap
            }
            y -= gap
        }
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-blue-dot.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
