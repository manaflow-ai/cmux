import AppKit
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

    @Test func paintingRendersAndClearsButOpaqueModeHidesIt() throws {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        view.wantsLayer = true
        var backdrop = WindowBackdrop(backgroundOpacity: 0, backgroundBlur: 0)
        view.apply(backdrop, tint: .white)
        let empty = try pixels(view)
        backdrop.art = .wheatField
        view.apply(backdrop, tint: .white)
        let painting = try pixels(view)
        #expect(painting != empty)
        backdrop.art = nil
        view.apply(backdrop, tint: .white)
        #expect(try pixels(view) == empty)
        var opaque = WindowBackdrop(backgroundOpacity: 0, backgroundBlur: -2, reduceTransparency: true)
        opaque.art = .wheatField
        view.apply(opaque, tint: .white)
        #expect(try pixels(view) == empty)
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

    private func pixels(_ view: NSView) throws -> [UInt8] {
        view.layoutSubtreeIfNeeded()
        let context = try #require(CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8,
                                            bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try #require(view.layer).render(in: context)
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: 64000))
    }
}
