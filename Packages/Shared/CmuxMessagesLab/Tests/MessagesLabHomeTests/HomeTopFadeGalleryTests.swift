import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The gallery of every ``HomeTopFadeStyle`` (cmux-galleries/chief-top-fade): the real Home view
/// over the mock owner, scrolled 260 pt up from the newest so rows sit under the header, drawn dark
/// and light, one style a row, in `.build/top-fade-gallery.png` (a fleet step returns it with
/// `--artifact`). An offscreen render draws masks, gradients and solid bands exactly, but no
/// backdrop blur: the glass, material, progressive blur and Messages bar rows show only their tint.
/// It checks only that every cell drew; the picture is for people.
extension HomeTopFadeStyleTests {
    static let cellSize = CGSize(width: 620, height: 300)

    @MainActor func renderCell(_ style: HomeTopFadeStyle, light: Bool) async throws -> CGImage? {
        let rig = try await HomeChatRig(history: 300, width: Self.cellSize.width)
        defer { rig.stop(); Fixture.lightAppearance = false }
        let view = rig.view
        rig.window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        view.controller.demo?.setLightAppearance(light)
        view.controller.host.headerBackdrop.setTint(Fixture.background)
        view.controller.demo?.backgroundColor = Fixture.background
        view.controller.host.paneHeader.light = light
        view.controller.host.paneHeader.title = "Chief"
        view.setTopFadeStyle(style)
        view.controller.host.applyTopFadeColors()
        rig.frame()
        let demo = try #require(view.controller.demo)
        demo.collection.contentOffset = CGPoint(x: 0, y: max(demo.minOffset, demo.pinnedOffset - 260))
        demo.userScrolled()
        for _ in 0..<4 {
            rig.frame()
            try await Task.sleep(for: .milliseconds(80))
        }
        guard let layer = view.layer else { return nil }
        let scale: CGFloat = 2, size = Self.cellSize
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor((light ? NSColor.white : NSColor(white: 0.12, alpha: 1)).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        // Only the pane's top: flip so the view's y-down top lands at the image's top.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    @MainActor @Test func galleryOfEveryStyle() async throws {
        var cells: [[CGImage]] = []
        for style in HomeTopFadeStyle.allCases {
            print("top-fade-gallery \(style.rawValue)")
            let dark = try #require(try await renderCell(style, light: false), "\(style) dark drew nothing")
            let light = try #require(try await renderCell(style, light: true), "\(style) light drew nothing")
            cells.append([dark, light])
        }
        let cw = Int(Self.cellSize.width * 2), ch = Int(Self.cellSize.height * 2), gap = 24
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: cw * 2 + gap * 3, height: (ch + gap) * cells.count + gap, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (row, pair) in cells.enumerated() {
            let y = ctx.height - (row + 1) * (ch + gap)
            for (col, image) in pair.enumerated() {
                ctx.draw(image, in: CGRect(x: gap + col * (cw + gap), y: y, width: cw, height: ch))
            }
        }
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/top-fade-gallery.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
