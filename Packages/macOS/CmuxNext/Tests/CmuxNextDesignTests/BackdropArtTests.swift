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

    @Test func systemSelectionPropagatesToSecondaryWindows() {
        let scope = ThemeScope(level: .room)
        let selection = BackdropSelection.system(path: "/System/Library/Desktop Pictures/Andromeda.heic")
        scope.setBackdropSelection(selection)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.install(kind: .settings, content: NSView(), scope: scope)
        #expect((window.contentView as? WindowSurfaceView)?.backdrop(in: window).selection == selection)
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
