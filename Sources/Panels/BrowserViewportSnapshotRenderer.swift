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
              plan.outputPixelCount <= BrowserViewportSnapshotPlan.maximumOutputPixelCount else {
            return nil
        }

        let outputSize = NSSize(width: width, height: height)
        if let representation = image.representations.first(where: { representation in
            plan.canReuseSourcePixels(CGSize(
                width: representation.pixelsWide,
                height: representation.pixelsHigh
            ))
        }) {
            guard image.size != outputSize else { return image }
            let output = NSImage(size: outputSize)
            output.addRepresentation(representation)
            return output
        }

        guard
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
