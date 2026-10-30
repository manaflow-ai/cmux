#if DEBUG
import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextTestSupport
import Testing

/// `debug.palette.capture` shows the open palette even when the window server has no image of its
/// panel (cx-ytt0): the Cmd-Shift-P palette opened over an inactive app captured as a flat gray
/// image, because the fallback drew only the layer tree on a backdrop.
@MainActor @Suite(.closesItsWindows)
struct DebugPaletteCaptureTests {
    @Test func aPaletteTheWindowServerCannotImageStillCapturesItsContent() throws {
        _ = NSApplication.shared
        let palette = PaletteController(registry: ActionRegistry.standard(), frecencyPersistence: nil)
        palette.show(.commands)
        let panel = try #require(palette.visiblePanel)
        // Hiding only orders the palette's panel out: close it too.
        defer { palette.hide(); panel.close() }
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("palette-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = DebugPaletteCapture.capture(panel, to: path, windowImage: { _ in nil })
        #expect(result.objectValue?["error"] == nil, "\(result)")
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: path))))
        // A flat image has a color or two; the palette's field, rows and text have many.
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colors.insert(UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8 | UInt32(color.blueComponent * 255))
            }
        }
        #expect(colors.count > 8, "the capture has \(colors.count) colors")
    }
}
#endif
