import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Where a background picture lies (`appearance.backgroundPlacement`, Leo 2026-11-22: "we also want
/// people to be able to reposition the images easily. the fast-actions need to be most accessible."):
/// the Swift mirror matches the table the Rust spec writes, Adjust Background…'s gestures move and
/// zoom as they should, and the art view draws a placement and gets its own look back without one.
struct BackdropPlacementMathTests {
    struct Case: Decodable {
        let image: [Double]
        let view: [Double]
        let placement: String
        let rect: [Double]?
        let frame: [Double]?
        let contents: [Double]?
    }

    struct Fixture: Decodable {
        let cases: [Case]
    }

    static func fixture() throws -> Fixture {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("cmux-tui/crates/cmux-config/tests/fixtures/backdrop-placement-cases.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
    }

    static func near(_ rect: CGRect, _ want: [Double], _ what: String) {
        let got = [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
        #expect(zip(got, want).allSatisfy { abs($0 - $1) < 1e-6 }, "\(what): \(got) is not \(want)")
    }

    @Test func theMirrorMatchesEveryRustCase() throws {
        let cases = try Self.fixture().cases
        #expect(cases.count > 10)
        for item in cases {
            let placement = try #require(BackdropPlacement(text: item.placement), "\(item.placement) does not read")
            #expect(placement.text == item.placement)
            let image = CGSize(width: item.image[0], height: item.image[1])
            let view = CGSize(width: item.view[0], height: item.view[1])
            let what = "\(item.placement) of \(image) in \(view)"
            if let want = item.rect { Self.near(try #require(placement.rect(image: image, view: view)), want, what) }
            if let frame = item.frame, let contents = item.contents {
                let shown = try #require(placement.visible(image: image, view: view))
                Self.near(shown.frame, frame, what)
                Self.near(shown.contents, contents, what)
            }
        }
    }

    @Test func outOfRangeTextsAreRefused() {
        for bad in ["", "cover", "fill 2 0.5", "fill 0.5", "fill 0.5 0.5 5", "fill 0.5 0.5 1 1", "fill x y"] {
            #expect(BackdropPlacement(text: bad) == nil, "\(bad) read")
        }
        #expect(BackdropPlacement.map(["a": "fit", "b": "nope", " ": "fit"]) == ["a": BackdropPlacement(mode: .fit)])
    }

    /// The overlay's drag is in bottom-left points: up on screen is up in the picture.
    @Test func theOverlaysDragFollowsThePointer() {
        let image = CGSize(width: 2000, height: 1000)
        let view = CGSize(width: 400, height: 400)
        // Filled: 800 wide, 400 of room; 100 points right moves the anchor a quarter toward the left edge.
        let right = BackdropAdjustOverlay.dragged(.centeredFill, image: image, view: view,
                                                  from: NSPoint(x: 0, y: 0), to: NSPoint(x: 100, y: 0))
        #expect(abs(right.x - 0.25) < 1e-9 && right.y == 0.5)
        // Fit, with room above and below: up on screen (y grows) is up in the window (the anchor toward the top).
        let fit = BackdropPlacement(mode: .fit)
        let up = BackdropAdjustOverlay.dragged(fit, image: image, view: view, from: NSPoint(x: 0, y: 0), to: NSPoint(x: 0, y: 50))
        #expect(up.y < 0.5)
        // Past the edge it clamps.
        #expect(BackdropAdjustOverlay.dragged(.centeredFill, image: image, view: view,
                                              from: .zero, to: NSPoint(x: 10_000, y: 0)).x == 0)
    }

    @Test func scrollAndPinchZoomWithinTheRange() {
        #expect(BackdropAdjustOverlay.scrollZoom(deltaY: 10, precise: true) > 1)
        #expect(BackdropAdjustOverlay.scrollZoom(deltaY: -10, precise: true) < 1)
        // A wheel's line zooms more than a trackpad's fine delta.
        #expect(BackdropAdjustOverlay.scrollZoom(deltaY: 1, precise: false) > BackdropAdjustOverlay.scrollZoom(deltaY: 1, precise: true))
        #expect(BackdropPlacement.centeredFill.zoomed(by: 100).zoom == BackdropPlacement.zoomRange.upperBound)
        #expect(BackdropPlacement.centeredFill.zoomed(by: 0.01).zoom == BackdropPlacement.zoomRange.lowerBound)
    }

    @Test func theBarsChoices() {
        let moved = BackdropPlacement(mode: .fill, x: 0.2, y: 0.8, zoom: 2)
        #expect(BackdropAdjustOverlay.choose(.fit, on: moved) == BackdropPlacement(mode: .fit, x: 0.2, y: 0.8))
        #expect(BackdropAdjustOverlay.choose(.fill, on: moved) == BackdropPlacement(mode: .fill, x: 0.2, y: 0.8))
        #expect(BackdropAdjustOverlay.choose(.center, on: moved) == BackdropPlacement(mode: .center))
        #expect(BackdropAdjustOverlay.choose(.reset, on: moved) == .centeredFill)
        #expect(BackdropAdjustOverlay.choose(.done, on: moved) == nil)
    }
}

/// The art view draws a placement in the part of the window it covers, and without one it keeps
/// the look `CustomBackgroundFillTests` and `ResizeInvariantTests` hold it to.
@MainActor @Suite(.serialized, .closesItsWindows) struct BackdropPlacementDrawTests {
    static func writeImage(width: Int, height: Int, in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent("placed-\(width)x\(height).png")
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)) // colour-allow: a test fixture's pixels
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return file
    }

    @Test func aPlacementDrawsAndTheUnplacedLookComesBack() async throws {
        _ = NSApplication.shared
        #expect(DesignSettings.shared.backgroundPlacements.isEmpty, "a test left a placement set")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("placed-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.writeImage(width: 400, height: 100, in: folder)
        let size = CGSize(width: 1000, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = root
        let backdrop = WindowMaterialView(frame: root.bounds, images: BackdropImageStore(maxPixelSize: 1600),
                                          videos: BackdropVideoPlayers(), fillsWindow: true)
        backdrop.autoresizingMask = [.width, .height]
        root.addSubview(backdrop)
        window.orderFrontRegardless()
        backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: .file(path: file.path)), tint: .black)
        await backdrop.artLoad?.value
        // Unset: the art view's own look.
        #expect(backdrop.placement == nil)
        #expect(backdrop.artView.frame == backdrop.bounds)
        #expect(backdrop.artView.layer?.contentsGravity == .resizeAspectFill)
        #expect(backdrop.glassImageFrame == nil)

        // Fit: the whole picture, across the width, centered top to bottom.
        let image = try #require(backdrop.placementImageSize)
        backdrop.previewPlacement = BackdropPlacement(mode: .fit)
        let fit = try #require(BackdropPlacement(mode: .fit).layerFrame(image: image, in: backdrop.bounds))
        #expect(backdrop.artView.frame == fit.frame)
        #expect(abs(fit.frame.width - size.width) < 0.5 && fit.frame.height < size.height)
        #expect(backdrop.artView.layer?.contentsGravity == .resize)
        #expect(backdrop.artView.layer?.contentsRect == fit.contentsRect)
        #expect(backdrop.glassImageFrame != nil)

        // Moved to the picture's left edge: the left part of the picture shows.
        backdrop.previewPlacement = BackdropPlacement(mode: .fill, x: 0, y: 0.5)
        let left = try #require(backdrop.artView.layer?.contentsRect)
        #expect(left.minX == 0 && left.width < 1)
        // It is laid out again on a resize.
        root.setFrameSize(CGSize(width: 700, height: 700))
        backdrop.layoutSubtreeIfNeeded()
        #expect(backdrop.artView.frame == BackdropPlacement(mode: .fill, x: 0, y: 0.5).layerFrame(image: image, in: backdrop.bounds)?.frame)

        // Without a placement the art follows the window by itself again.
        backdrop.previewPlacement = nil
        #expect(backdrop.artView.frame == backdrop.bounds)
        #expect(backdrop.artView.layer?.contentsGravity == .resizeAspectFill)
        #expect(backdrop.artView.layer?.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1))
        root.setFrameSize(size)
        #expect(backdrop.artView.frame == backdrop.bounds)
    }
}
