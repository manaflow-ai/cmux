import AppKit
import CmuxBrowser

struct BrowserViewportSnapshotRenderer {
    let plan: BrowserViewportSnapshotPlan

    var snapshotWidth: NSNumber {
        NSNumber(value: plan.snapshotPointWidth)
    }

    func normalizedImage(_ image: NSImage) -> NSImage? {
        let width = Int(plan.outputPixelSize.width.rounded())
        let height = Int(plan.outputPixelSize.height.rounded())
        guard width > 0,
              height > 0,
              plan.outputPixelCount <= BrowserViewportSnapshotPlan.maximumOutputPixelCount,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: width,
                  pixelsHigh: height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        let outputSize = NSSize(width: width, height: height)
        bitmap.size = outputSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: outputSize).fill()
        image.draw(
            in: NSRect(origin: .zero, size: outputSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: outputSize)
        output.addRepresentation(bitmap)
        return output
    }
}
