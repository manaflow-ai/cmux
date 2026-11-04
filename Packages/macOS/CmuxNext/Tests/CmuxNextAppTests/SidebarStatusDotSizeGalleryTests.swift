import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence msg 19696 ("dots are different size now which is very bad"): the sidebar's right edge with every
/// kind of status dot (`SidebarStatusDotSizeTests.Harness`), light and dark, at compact density. Each crop
/// draws a 1 px guide on the trailing column's center and labels each dot with its measured ink diameter.
/// Artifact `sidebar-dot-size-gallery.tar` (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarStatusDotSizeGalleryTests {
    typealias T = SidebarStatusDotSizeTests

    /// The right edge kept in a crop, and the label strip after it, in points.
    static let cropWidth: CGFloat = 90, stripWidth: CGFloat = 120

    static func render(_ view: NSView) throws -> CGImage {
        for sub in AANestedGroupsGalleryTests.all(view) { sub.layoutSubtreeIfNeeded(); sub.needsDisplay = true; sub.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    /// The right edge of `h`'s sidebar with the column guide and each dot's diameter.
    static func crop(_ h: T.Harness, dark: Bool) throws -> CGImage {
        let content = try #require(h.window.contentView)
        let image = try render(content)
        let scale = CGFloat(image.width) / content.bounds.width
        // Content points with a bottom-left origin, as the context below draws.
        func up(_ r: CGRect) -> CGRect {
            content.isFlipped ? CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height) : r
        }
        var dots: [(String, CGRect)] = []
        var rowsBox = CGRect.null
        for (name, row) in try h.dotRows() + [("failed", try h.row(.workspace(T.failed)))] {
            rowsBox = rowsBox.union(up(content.convert(row.bounds, from: row)))
            for dot in T.dots(in: row, named: name, list: h.list).dots {
                dots.append((dot.what, up(content.convert(dot.ink, from: h.list))))
            }
        }
        let columnX = content.convert(CGPoint(x: try h.columnX(), y: 0), from: h.list).x
        let cropX = content.bounds.width - cropWidth
        let box = CGRect(x: cropX, y: rowsBox.minY - 6, width: cropWidth + stripWidth, height: rowsBox.height + 12)
        let px = { (v: CGFloat) in Int((v * scale).rounded()) }
        let context = try #require(CGContext(data: nil, width: px(box.width), height: px(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.draw(image, in: CGRect(x: -box.minX * scale, y: -box.minY * scale, width: CGFloat(image.width), height: CGFloat(image.height)))
        // The strip after the crop holds the labels.
        context.setFillColor(dark ? CGColor(gray: 0.05, alpha: 1) : CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: cropWidth * scale, y: 0, width: stripWidth * scale, height: box.height * scale))
        // The column's center: one device pixel.
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 0.9))
        context.fill(CGRect(x: ((columnX - box.minX) * scale).rounded(.down), y: 0, width: 1, height: box.height * scale))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let font = NSFont.monospacedSystemFont(ofSize: 9 * scale, weight: .medium)
        let ink: NSColor = dark ? .white : .black
        for (what, rect) in dots {
            let text = String(format: "%.2f pt  %@", rect.width, String(what.prefix(while: { $0 != "." })))
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
            let y = (rect.midY - box.minY) * scale - string.size().height / 2
            string.draw(at: CGPoint(x: (cropWidth + 4) * scale, y: y))
            // A tick from the dot to its label.
            context.setFillColor(ink.withAlphaComponent(0.35).cgColor)
            context.fill(CGRect(x: (rect.maxX - box.minX + 2) * scale, y: ((rect.midY - box.minY) * scale).rounded(.down),
                                width: (cropWidth - (rect.maxX - box.minX) - 2) * scale, height: 1))
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(context.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderTheDotsLightAndDark() throws {
        Motion.reduceMotionOverride = false // under Reduce Motion done draws a check, not the dot
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-dot-size-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for density in [SidebarDensity.compact, .comfortable] {
            try SidebarGroupRailAlignmentTests.with(density, .off) {
                for dark in [false, true] {
                    let h = T.Harness(width: 280, appearance: dark ? .darkAqua : .aqua)
                    defer { h.window.close() }
                    let content = try #require(h.window.contentView)
                    content.wantsLayer = true
                    var background = CGColor(gray: 1, alpha: 1)
                    (h.window.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                        background = NSColor.windowBackgroundColor.cgColor
                    }
                    content.layer?.backgroundColor = background
                    let name = "dot-size-\(density.rawValue)-\(dark ? "dark" : "light").png"
                    try AAGroupHeaderDensityGalleryTests.write(try Self.crop(h, dark: dark), to: out.appending(path: name))
                }
            }
        }
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-dot-size-gallery.tar", "sidebar-dot-size-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
