import AppKit
import Foundation
import Testing
@testable import CmuxNextDesign

@MainActor
struct BackdropArtTests {
    @Test func packagedPaintingDecodes() throws {
        let image = try #require(BackdropArt.wheatField.image())
        #expect(image.isValid)
        #expect(image.size.width > 500)
        #expect(image.size.height > 500)
    }

    @Test func eachPaintingPublishesLayoutMetadata() {
        for art in BackdropArt.allCases {
            let metadata = art.metadata
            #expect((0...1).contains(metadata.focalAnchor.x))
            #expect((0...1).contains(metadata.focalAnchor.y))
            #expect(!metadata.dominantPalette.isEmpty)
            #expect(metadata.quietZone.width > 0)
            #expect(metadata.quietZone.height > 0)
        }

        #expect(BackdropArt.wheatField.metadata.tone == .light)
        #expect(BackdropArt.portraitAtCasement.metadata.tone == .dark)
        #expect(BackdropArt.wheatField.metadata.focalAnchor.x > 0.5)
    }

    @Test func cropRectFollowsFocalAnchorForAspectFill() {
        let metadata = BackdropArt.wheatField.metadata
        let crop = metadata.cropRect(forViewSize: CGSize(width: 2_000, height: 800),
                                     imageSize: CGSize(width: 2_400, height: 1_910))

        #expect(crop.width == 1)
        #expect(crop.height < 1)
        #expect(crop.minX == 0)
        #expect(crop.minY >= 0)
        #expect(crop.maxY <= 1)
        #expect(crop.midY > 0.35)
        #expect(crop.midY < 0.65)
    }

    @Test func windowMaterialUsesThePaintingFocalCrop() async throws {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 2_000, height: 800))
        var backdrop = WindowBackdrop(backgroundOpacity: 0, backgroundBlur: 0)
        backdrop.art = .wheatField
        view.apply(backdrop, tint: .white)
        await view.artLoaded()
        view.layoutSubtreeIfNeeded()
        let artLayer = try #require(view.subviews.first?.layer)
        let image = try #require(BackdropArt.wheatField.image())
        let expected = BackdropArt.wheatField.metadata.cropRect(forViewSize: view.bounds.size,
                                                                 imageSize: image.size)
        #expect(artLayer.contentsRect == expected)
    }

    @Test func catalogContainsBundledCC0PaintingsAndEnumeratesSystemFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0x01]).write(to: directory.appendingPathComponent("z-wallpaper.jpg"))
        try Data([0x01]).write(to: directory.appendingPathComponent("a-wallpaper.png"))
        let catalog = BackdropCatalog(systemDirectory: directory, fileManager: .default, systemLimit: 1)
        #expect(catalog.choices.count == BackdropArt.allCases.count + 1)
        let firstSystem = try #require(catalog.choices.dropFirst(BackdropArt.allCases.count).first)
        guard case .system(let actualPath) = firstSystem else {
            Issue.record("The first system wallpaper choice was not a system path")
            return
        }
        let actualURL = URL(fileURLWithPath: actualPath).resolvingSymlinksInPath()
        let expectedURL = directory.appendingPathComponent("a-wallpaper.png").resolvingSymlinksInPath()
        #expect(actualURL == expectedURL)
    }

    @Test func tuningClampsAndPreservesUnchangedAxes() {
        let tuning = AppearanceTuning(glassTransparency: 4, hue: .nan, saturation: -2)
        #expect(tuning == AppearanceTuning(glassTransparency: 1, hue: 0.5, saturation: 0))
        #expect(tuning.setting(.hue, to: 0.25) == AppearanceTuning(glassTransparency: 1, hue: 0.25, saturation: 0))
    }

    @Test func artInheritsAcrossScopesAndClearsWithoutChangingColors() {
        let root = ThemeScope(level: .room)
        let child = ThemeScope(level: .workspace, parent: root)
        let original = child.tokens
        root.setBackdropArt(.wheatField)
        #expect(child.backdropArt == .wheatField)
        #expect(child.tokens == original)
        root.setBackdropArt(nil)
        #expect(child.backdropArt == nil)
        #expect(child.tokens == original)
    }

    /// The art view composites the painting, shows nothing once the art is
    /// cleared, and hides it in opaque mode. It reads the art layer the
    /// window composites (shown or hidden, and the pixels of its contents)
    /// rather than `CALayer.render(in:)` of the view: outside a window AppKit
    /// does not attach the art view's layer to the view's layer, and
    /// `render(in:)` draws no NSImage contents, so that measure was all
    /// zero with or without a painting (fleet probe, 2026-10-05).
    @Test func paintingRendersAndClearsButOpaqueModeHidesIt() async throws {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        view.wantsLayer = true
        var backdrop = WindowBackdrop(backgroundOpacity: 0, backgroundBlur: 0)
        view.apply(backdrop, tint: .white)
        #expect(try shownArt(view) == nil)
        backdrop.art = .wheatField
        view.apply(backdrop, tint: .white)
        await view.artLoaded()
        let painting = try #require(try shownArt(view), "the painting is shown")
        #expect(painting.contains { $0 != 0 }, "the shown painting has pixels")
        backdrop.art = nil
        view.apply(backdrop, tint: .white)
        #expect(try shownArt(view) == nil)
        var opaque = WindowBackdrop(backgroundOpacity: 0, backgroundBlur: -2, reduceTransparency: true)
        opaque.art = .wheatField
        view.apply(opaque, tint: .white)
        #expect(try shownArt(view) == nil)
    }

    /// Launch's first frame draws the theme's colors at once; the painting
    /// decodes off the main actor and shows on a later frame (sweep 4a: the
    /// 2400 px painting cost the first frame about 50 ms).
    @Test func theFirstWindowsPaintingDecodesOffTheMainActorThenShows() async throws {
        let images = BackdropImageStore()
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 160, height: 100), images: images)
        view.wantsLayer = true
        var backdrop = WindowBackdrop(backgroundOpacity: 0, backgroundBlur: 0)
        backdrop.art = .wheatField
        view.apply(backdrop, tint: .white)
        #expect(try shownArt(view) == nil, "apply does not decode the painting")
        await view.artLoaded()
        let painting = try #require(try shownArt(view), "the decoded painting is shown")
        #expect(painting.contains { $0 != 0 })
        #expect(images.cached(.art(.wheatField)) != nil)
    }

    @Test func aLaterWindowShowsTheDecodedPaintingAtOnce() async throws {
        let images = BackdropImageStore()
        var backdrop = WindowBackdrop(backgroundOpacity: 0, backgroundBlur: 0)
        backdrop.art = .wheatField
        _ = await images.image(.art(.wheatField))
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 160, height: 100), images: images)
        view.wantsLayer = true
        view.apply(backdrop, tint: .white)
        #expect(try shownArt(view) != nil)
    }

    @Test(arguments: WindowKind.allCases)
    func everySecondaryWindowUsesTheSameArt(_ kind: WindowKind) {
        guard kind.traits.surface == .backdrop else { return }
        _ = NSApplication.shared
        let scope = ThemeScope(level: .room)
        scope.setBackdropArt(.wheatField)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.install(kind: kind, content: NSView(), scope: scope)
        #expect((window.contentView as? WindowSurfaceView)?.backdrop(in: window).art == .wheatField)
        scope.setBackdropArt(nil)
        #expect((window.contentView as? WindowSurfaceView)?.backdrop(in: window).art == nil)
    }

    @Test func systemSelectionPropagatesToSecondaryWindows() {
        let scope = ThemeScope(level: .room)
        let selection = BackdropSelection.system(path: "/System/Library/Desktop Pictures/Andromeda.heic")
        scope.setBackdropSelection(selection)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.install(kind: .settings, content: NSView(), scope: scope)
        #expect((window.contentView as? WindowSurfaceView)?.backdrop(in: window).selection == selection)
    }

    /// The pixels the art layer composites (its contents through its
    /// contents rect, at the view's size), or nil while it shows nothing.
    private func shownArt(_ view: NSView) throws -> [UInt8]? {
        view.layoutSubtreeIfNeeded()
        let art = try #require(view.subviews.first)
        let layer = try #require(art.layer)
        guard !art.isHiddenOrHasHiddenAncestor, layer.opacity > 0, let contents = layer.contents else { return nil }
        let image = try #require(contents as? NSImage)
        let bitmap = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rect = layer.contentsRect
        let crop = CGRect(x: rect.minX * CGFloat(bitmap.width), y: (1 - rect.maxY) * CGFloat(bitmap.height),
                          width: rect.width * CGFloat(bitmap.width), height: rect.height * CGFloat(bitmap.height)).integral
        let shown = try #require(bitmap.cropping(to: crop))
        let context = try #require(CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8,
                                            bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(shown, in: CGRect(x: 0, y: 0, width: 160, height: 100))
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: 64000))
    }
}
