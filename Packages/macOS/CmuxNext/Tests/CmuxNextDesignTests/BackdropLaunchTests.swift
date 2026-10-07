import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxNextDesign

/// Art shows without a launch flash (cx-t2x.3): backdrops decode no larger than the screen, the
/// texture pass renders off the main actor into a bitmap, the result is kept on disk, and the
/// next launch's first window shows that snapshot in its first frame. Picking art starts the
/// decode before any window asks.
@MainActor
struct BackdropLaunchTests {
    @Test func aBackdropDecodesNoLargerThanTheScreen() async throws {
        let store = BackdropImageStore(maxPixelSize: 600)
        let image = try #require(await store.image(.art(.wheatField)))
        let bitmap = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(bitmap.width > 0 && bitmap.height > 0)
        #expect(max(bitmap.width, bitmap.height) <= 600, "\(bitmap.width)x\(bitmap.height)")
    }

    /// The texture pass is done before the image reaches the main actor: a bitmap, not a lazy
    /// Core Image representation AppKit would render in the commit, and only once per source
    /// and texture.
    @Test func theTextureRendersOnceIntoABitmap() async throws {
        let store = BackdropImageStore(maxPixelSize: 600)
        let texture = BackdropTexture(filter: .orderedDither4x4, strength: 0.2)
        let first = try #require(await store.image(.art(.wheatField), texture: texture))
        let second = try #require(await store.image(.art(.wheatField), texture: texture))
        #expect(first === second)
        #expect(store.renderCount == 1)
        #expect(!first.representations.contains { $0 is NSCIImageRep })
        let halftone = try #require(await store.image(.art(.wheatField), texture: BackdropTexture(filter: .halftone, strength: 0.2)))
        #expect(halftone !== first)
        #expect(store.renderCount == 2)
    }

    /// Every filter renders without raising (CIFilter raises for a key it does not declare,
    /// which ends the process) and keeps the source's size.
    @Test(arguments: BackdropTextureFilter.allCases)
    func everyFilterRendersTheSourceSize(_ filter: BackdropTextureFilter) async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.fixture(in: directory, width: 32, height: 20)
        let store = BackdropImageStore(maxPixelSize: 600)
        let image = try #require(await store.image(.system(path: file.path), texture: BackdropTexture(filter: filter, strength: 0.5)))
        let bitmap = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(bitmap.width == 32 && bitmap.height == 20)
    }

    /// A store with the snapshots of an earlier launch shows the art in the window's first
    /// frame, then swaps in the full image without fading it in.
    @Test func theNextLaunchShowsTheArtInItsFirstFrame() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await BackdropImageStore(maxPixelSize: 600, snapshots: directory).image(.art(.wheatField))

        let relaunched = BackdropImageStore(maxPixelSize: 600, snapshots: directory)
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 160, height: 100), images: relaunched)
        view.wantsLayer = true
        var backdrop = WindowBackdrop(backgroundOpacity: 0, backgroundBlur: 0)
        backdrop.art = .wheatField
        view.apply(backdrop, tint: .white)
        #expect(Self.shownImage(view) != nil, "the first frame shows the snapshot")
        await view.artLoaded()
        #expect(Self.shownImage(view) != nil)
        #expect(view.subviews.first?.layer?.animation(forKey: "fadeIn") == nil, "no fade over the snapshot")
    }

    /// A snapshot belongs to the file it was made from: a replaced file decodes again.
    @Test func aReplacedFileIsNotServedFromItsSnapshot() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshots = directory.appendingPathComponent("snapshots", isDirectory: true)
        let file = try Self.fixture(in: directory, width: 32, height: 20)
        _ = await BackdropImageStore(maxPixelSize: 600, snapshots: snapshots).image(.system(path: file.path))
        try FileManager.default.removeItem(at: file)
        _ = try Self.fixture(in: directory, width: 48, height: 24)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)

        let image = try #require(await BackdropImageStore(maxPixelSize: 600, snapshots: snapshots).image(.system(path: file.path)))
        let bitmap = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(bitmap.width == 48 && bitmap.height == 24)
    }

    /// Settings pick the art before the first window exists; the shared store starts decoding
    /// it then, so the window finds it ready.
    @Test func pickingArtDecodesItBeforeAnyWindowAsks() async {
        let scope = ThemeScope(level: .room)
        defer { scope.setBackdropSelection(nil) }
        scope.setBackdropSelection(.art(.womenPickingOlives))
        await BackdropImageStore.shared.settled()
        #expect(BackdropImageStore.shared.cached(.art(.womenPickingOlives)) != nil)
    }

    private static func shownImage(_ view: NSView) -> NSImage? {
        guard let art = view.subviews.first, !art.isHidden else { return nil }
        return art.layer?.contents as? NSImage
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backdrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A two-color PNG at `fixture.png` in `directory`.
    private static func fixture(in directory: URL, width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.75, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let image = try #require(context.makeImage())
        let file = directory.appendingPathComponent("fixture.png")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return file
    }
}
