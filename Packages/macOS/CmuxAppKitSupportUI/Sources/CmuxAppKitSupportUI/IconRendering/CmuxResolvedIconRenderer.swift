public import AppKit
public import Foundation

/// Renders small AppKit icons after resolving asset variants, template masks, and dynamic colors.
@MainActor
public final class CmuxResolvedIconRenderer {
    private let rasterScale: CGFloat = 2

    /// Creates an icon renderer.
    public init() {}

    /// Returns a non-template image rasterized for the supplied appearance.
    /// - Parameters:
    ///   - request: Icon render request.
    ///   - appearance: Appearance used to resolve dynamic colors and asset variants.
    /// - Returns: A copied, sized image, or `nil` when the source is missing or draws blank.
    public func image(for request: CmuxResolvedIconRequest, appearance: NSAppearance) -> NSImage? {
        try? render(for: request, appearance: appearance).get()
    }

    /// Renders a non-template image for the supplied appearance.
    /// - Parameters:
    ///   - request: Icon render request.
    ///   - appearance: Appearance used to resolve dynamic colors and asset variants.
    /// - Returns: A visible image, or a failure that distinguishes missing sources from blank output.
    public func render(
        for request: CmuxResolvedIconRequest,
        appearance: NSAppearance
    ) -> Result<NSImage, CmuxResolvedIconRenderFailure> {
        guard let imageSize = normalizedSize(request.size) else {
            return .failure(.sourceUnavailable)
        }
        var output: NSImage?
        var failure = CmuxResolvedIconRenderFailure.sourceUnavailable
        appearance.performAsCurrentDrawingAppearance {
            guard let sourceImage = resolvedSourceImage(for: request),
                  let bitmap = bitmapRepresentation(size: imageSize) else {
                failure = .sourceUnavailable
                return
            }
            bitmap.size = imageSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            defer { NSGraphicsContext.restoreGraphicsState() }

            NSColor.clear.setFill()
            NSRect(origin: .zero, size: imageSize).fill()
            NSGraphicsContext.current?.imageInterpolation = .high

            let drawRect = drawingRect(for: sourceImage.size, in: imageSize)
            sourceImage.draw(
                in: drawRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )

            if let tintColor = request.tintColor {
                tintColor.setFill()
                NSRect(origin: .zero, size: imageSize).fill(using: .sourceAtop)
            }
            guard containsVisiblePixels(in: bitmap) else {
                failure = .blankOutput
                return
            }
            let rendered = NSImage(size: imageSize)
            rendered.addRepresentation(bitmap)
            rendered.cacheMode = .never
            rendered.isTemplate = false
            output = rendered
        }
        if let output {
            return .success(output)
        }
        return .failure(failure)
    }

    /// Returns PNG data for an icon rendered under the supplied appearance.
    public func pngData(for request: CmuxResolvedIconRequest, appearance: NSAppearance) -> Data? {
        guard let image = image(for: request, appearance: appearance),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return representation.representation(using: .png, properties: [:])
    }

    private func resolvedSourceImage(for request: CmuxResolvedIconRequest) -> NSImage? {
        switch request.source {
        case .systemSymbol(let name, let accessibilityDescription):
            guard let baseImage = NSImage(
                systemSymbolName: name,
                accessibilityDescription: accessibilityDescription
            ) else {
                return nil
            }
            let pointSize = max(1, min(request.size.width, request.size.height))
            let configuration = NSImage.SymbolConfiguration(
                pointSize: pointSize,
                weight: request.symbolWeight
            )
            let configured = baseImage.withSymbolConfiguration(configuration) ?? baseImage
            let image = copiedImage(configured)
            return image
        case .asset(let name, let bundle):
            guard let image = bundle.image(forResource: name) ?? NSImage(named: name) else {
                return nil
            }
            return copiedImage(image)
        case .image(let image):
            image.recache()
            return copiedImage(image)
        }
    }

    private func copiedImage(_ image: NSImage) -> NSImage {
        let copy = (image.copy() as? NSImage) ?? image
        copy.cacheMode = .never
        copy.isTemplate = false
        copy.recache()
        return copy
    }

    private func bitmapRepresentation(size: NSSize) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(ceil(size.width * rasterScale))),
            pixelsHigh: max(1, Int(ceil(size.height * rasterScale))),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }

    private func containsVisiblePixels(in bitmap: NSBitmapImageRep) -> Bool {
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                    return true
                }
            }
        }
        return false
    }

    private func normalizedSize(_ size: NSSize) -> NSSize? {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func drawingRect(for sourceSize: NSSize, in targetSize: NSSize) -> NSRect {
        guard sourceSize.width.isFinite,
              sourceSize.height.isFinite,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return NSRect(origin: .zero, size: targetSize)
        }
        let scale = min(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
        let width = sourceSize.width * scale
        let height = sourceSize.height * scale
        return NSRect(
            x: (targetSize.width - width) / 2,
            y: (targetSize.height - height) / 2,
            width: width,
            height: height
        )
    }
}
