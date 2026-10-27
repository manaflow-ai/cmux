import AppKit
@testable import CmuxNextDesign
import Testing

/// A dialog's icon (an extension prompt's) decodes in the dialog's build at 2x of its 40 pt, and only within the main
/// thread's image gate (p03-rendering-121): Chromium's 128 px prompt icon shows at 80 px; a 512 px one (1 MiB of
/// pixels) is not decoded on the main thread, and the dialog shows no icon.
@MainActor
struct CmuxDialogIconDecodeTests {
    private static func png(side: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// The images the dialog shows at its icon size.
    private static func icons(_ view: NSView) -> [NSImage] {
        let side = CmuxDialogMetrics.iconSize
        var found: [NSImage] = []
        if let image = (view as? NSImageView)?.image, image.size == NSSize(width: side, height: side) { found.append(image) }
        for subview in view.subviews { found += icons(subview) }
        return found
    }

    private static func dialog(icon: Data) -> CmuxDialogView {
        CmuxDialogView(spec: CmuxDialogSpec(title: "Add “Ext”?", buttons: [.ok("Add")], icon: icon))
    }

    @Test func aPromptIconDecodesAtTheDialogSize() throws {
        let shown = Self.icons(Self.dialog(icon: try Self.png(side: 128)))
        try #require(shown.count == 1)
        #expect(shown[0].representations.first?.pixelsWide == Int(CmuxDialogMetrics.iconSize * 2))
    }

    @Test func anIconPastTheMainThreadGateIsNotDecoded() throws {
        #expect(Self.icons(Self.dialog(icon: try Self.png(side: 512))).isEmpty)
    }
}
