import AppKit
@testable import CmuxNextDesign
import Testing

/// A window's backdrop art that decodes after the first frame fades in on the motion settings'
/// fade-in (cx-yt7ya): a literal 0.2 s ran at every animation speed, off included.
@MainActor
struct BackdropArtFadeTests {
    /// A small image file in a new temporary folder.
    static func imageFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = folder.appendingPathComponent("art.png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    /// Every opacity animation on `layer` and the layers under it.
    static func opacityFades(under layer: CALayer?) -> [CABasicAnimation] {
        guard let layer else { return [] }
        let own = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CABasicAnimation }.filter { $0.keyPath == "opacity" }
        return own + (layer.sublayers ?? []).flatMap { opacityFades(under: $0) }
    }

    @Test func artDecodedLaterFadesInOnTheFadeInToken() async throws {
        let url = try Self.imageFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), images: BackdropImageStore())
        var backdrop = WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 0)
        backdrop.selection = .file(path: url.path)
        view.apply(backdrop, tint: .black)
        var fades: [CABasicAnimation] = []
        for _ in 0..<200 where fades.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            // Each part has its own layer; the view itself has none outside a window.
            fades = view.subviews.flatMap { Self.opacityFades(under: $0.layer) }
        }
        // At speed off the art appears at once (no fade to find).
        if Motion.duration(.fadeIn) > 0 { try #require(!fades.isEmpty, "the art never faded in") }
        let duration = fades.first?.duration ?? 0
        #expect(duration == Motion.duration(.fadeIn), "the art fade ran \(duration) s")
    }
}
