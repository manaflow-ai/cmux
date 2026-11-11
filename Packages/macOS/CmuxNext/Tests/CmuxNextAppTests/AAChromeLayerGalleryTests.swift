import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// Whole-window stills of the chrome layer (sidebar list, footer, titlebar) with a pixel check of each region
/// against `schemas/theme/chrome-layer-colors.json`, the colours of the base build (`ChromeLayerColorTests`).
/// Leo, 2026-11-11, after #39984's sidebar dim: "bro why is the sidebar now a different color?"
/// Three variants under `chrome-layer-gallery/`: the default dark and light themes, whose pixels match the
/// recorded colours, and the dark theme with #39984's 0.2 dim (`sidebar.surfaceDim.dark`), whose sidebar list
/// does not: the mismatch the check catches. `all.png` holds the three side by side, bundled to
/// `chrome-layer-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAChromeLayerGalleryTests {
    struct Variant {
        let file: String
        let theme: (name: String, dark: Bool)
        let dim: Double?
    }

    static let variants = [
        Variant(file: "dark-default", theme: ChromeLayerColorTests.themes[0], dim: nil),
        Variant(file: "light-default", theme: ChromeLayerColorTests.themes[1], dim: nil),
        Variant(file: "dark-dim-0.2", theme: ChromeLayerColorTests.themes[0], dim: 0.2),
    ]

    /// The window drawn (`cacheDisplay`) over its surface, and each region's pixel as `#RRGGBB`.
    static func render(_ variant: Variant) async throws -> (CGImage, [String: String]) {
        if let dim = variant.dim { TunableStore.shared.set(ChromeLayerColorTests.dimKey, .number(dim)) }
        defer { if variant.dim != nil { TunableStore.shared.set(ChromeLayerColorTests.dimKey, nil) } }
        return try await ChromeLayerColorTests.inTheme(variant.theme.name) {
            let (window, root) = ChromeLayerColorTests.openRoot(dark: variant.theme.dark)
            defer { window.close() }
            window.orderFrontRegardless()
            await ChromeLayerColorTests.settle(root) { false }
            for view in AANestedGroupsGalleryTests.all(root) {
                view.layoutSubtreeIfNeeded()
                view.layer?.removeAllAnimations()
                view.needsDisplay = true
                view.displayIfNeeded()
            }
            CATransaction.flush()
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            let shot = try #require(rep.cgImage)
            // Over the window's own surface, as the window's backdrop shows under the content view.
            let surface = root.themeTokens.surfaceBackground.withAlpha(1)
            let ctx = try #require(CGContext(data: nil, width: shot.width, height: shot.height, bitsPerComponent: 8,
                                             bytesPerRow: shot.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(srgbRed: surface.red, green: surface.green, blue: surface.blue, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
            ctx.draw(shot, in: CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
            let image = try #require(ctx.makeImage())
            let scale = CGFloat(shot.width) / root.bounds.width
            let bytes = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
            var pixels: [String: String] = [:]
            for (region, point) in ChromeLayerColorTests.points(root) {
                // The context's rows run top down in memory; a non-flipped root's y runs bottom up.
                let x = Int((point.x * scale).rounded(.down))
                let yFromTop = root.isFlipped ? point.y : root.bounds.height - point.y
                let y = min(shot.height - 1, max(0, Int((yFromTop * scale).rounded(.down))))
                let offset = y * shot.width * 4 + x * 4
                let rgb = ThemeRGB(red: Double(bytes[offset]) / 255, green: Double(bytes[offset + 1]) / 255,
                                   blue: Double(bytes[offset + 2]) / 255)
                pixels[region] = ChromeLayerHex.hex(rgb)
            }
            return (image, pixels)
        }
    }

    /// Channels of two `#RRGGBB` colours within `tolerance` (8-bit steps).
    static func near(_ a: String?, _ b: String?, tolerance: Int = 3) -> Bool {
        guard let a, let b, a.count == 7, b.count == 7 else { return false }
        let pa = stride(from: 1, to: 7, by: 2).map { Int(a.dropFirst($0).prefix(2), radix: 16) ?? -999 }
        let pb = stride(from: 1, to: 7, by: 2).map { Int(b.dropFirst($0).prefix(2), radix: 16) ?? 999 }
        return zip(pa, pb).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// Runs only with `CMUX_TEST_REQUIRE_GUI` set (the fleet's opt-in for drawing tests): it writes files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() async throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "chrome-layer-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let recorded = try ChromeLayerColorTests.fileRows()
        var images: [CGImage] = []
        var report: [String] = []
        for variant in Self.variants {
            let (image, pixels) = try await Self.render(variant)
            images.append(image)
            try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(variant.file).png"))
            let base = recorded[variant.theme.name] ?? [:]
            report.append("\(variant.file): " + ChromeLayerColorTests.regions.map { "\($0) \(pixels[$0] ?? "?") (base \(base[$0] ?? "?"))" }
                .joined(separator: ", "))
            if variant.dim == nil {
                for region in ChromeLayerColorTests.regions {
                    #expect(Self.near(pixels[region], base[region]),
                            "\(variant.file): the \(region) shows \(pixels[region] ?? "?"), the base build \(base[region] ?? "?")")
                }
            } else {
                // #39984's dim: the list no longer matches the base build or the titlebar beside it.
                #expect(!Self.near(pixels["sidebar"], base["sidebar"]), "\(variant.file): the dim did not show: \(pixels)")
                #expect(!Self.near(pixels["sidebar"], pixels["titlebar"]), "\(variant.file): the dimmed list matched the titlebar")
            }
        }
        try (report.joined(separator: "\n") + "\n").write(to: out.appending(path: "pixels.txt"), atomically: true, encoding: .utf8)
        print("chrome-layer-gallery:\n" + report.joined(separator: "\n"))
        let w = images[0].width, h = images[0].height, gap = 16
        let ctx = try #require(CGContext(data: nil, width: images.count * w + (images.count - 1) * gap, height: h, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in images.enumerated() {
            ctx.draw(image, in: CGRect(x: i * (w + gap), y: 0, width: image.width, height: image.height))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "chrome-layer-gallery.tar", "chrome-layer-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
