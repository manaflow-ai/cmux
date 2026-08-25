import AppKit

/// Materializes small icons under an explicit appearance before they reach layout.
@MainActor
final class CmuxResolvedIconRenderer {
    private let rasterScales: [CGFloat] = [2, 1]

    /// Returns a visible, non-template image or `nil` when no candidate succeeds.
    func image(
        for request: CmuxResolvedIconRequest,
        appearance: NSAppearance
    ) -> NSImage? {
        try? render(for: request, appearance: appearance).get()
    }

    /// Resolves and rasterizes a request, distinguishing missing sources from blank draws.
    func render(
        for request: CmuxResolvedIconRequest,
        appearance: NSAppearance
    ) -> Result<NSImage, CmuxResolvedIconRenderFailure> {
        guard let imageSize = normalizedSize(request.size), !request.sources.isEmpty else {
            return .failure(.sourceUnavailable)
        }

        var failure = CmuxResolvedIconRenderFailure.sourceUnavailable
        var output: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            for source in request.sources {
                // A symbol provider can hand back a lazy representation on
                // its first lookup. Resolve it again once, synchronously and
                // without a timer, before falling through to the next source.
                for _ in 0..<2 {
                    guard let sourceImage = resolvedSourceImage(
                        source,
                        request: request,
                        size: imageSize
                    ) else {
                        break
                    }

                    switch render(
                        sourceImage,
                        size: imageSize,
                        tintColor: request.tintColor ?? defaultTint(for: source)
                    ) {
                    case .success(let image):
                        output = image
                        return
                    case .failure(let renderFailure):
                        failure = renderFailure
                    }
                }
            }
        }

        if let output {
            return .success(output)
        }
        return .failure(failure)
    }

    /// Returns PNG bytes for a rendered request, suitable for tab metadata.
    func pngData(
        for request: CmuxResolvedIconRequest,
        appearance: NSAppearance
    ) -> Data? {
        guard let image = image(for: request, appearance: appearance),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private func resolvedSourceImage(
        _ source: CmuxResolvedIconSource,
        request: CmuxResolvedIconRequest,
        size: NSSize
    ) -> NSImage? {
        switch source {
        case .systemSymbol(let name, let accessibilityDescription):
            guard let baseImage = NSImage(
                systemSymbolName: name,
                accessibilityDescription: accessibilityDescription
            ) else {
                return nil
            }
            let pointSize = max(1, min(size.width, size.height))
            let configuration = NSImage.SymbolConfiguration(
                pointSize: pointSize,
                weight: request.symbolWeight
            )
            let configured = baseImage.withSymbolConfiguration(configuration) ?? baseImage
            let copied = copiedImage(configured)
            // Direct bitmap drawing must not ask AppKit to perform a second
            // template-tint pass; tint is applied explicitly below.
            copied.isTemplate = false
            return copied
        case .asset(let name, let bundle):
            guard let image = bundle.image(forResource: name) ?? NSImage(named: name) else {
                return nil
            }
            return copiedImage(image)
        case .image(let image):
            return copiedImage(image)
        }
    }

    private func render(
        _ sourceImage: NSImage,
        size: NSSize,
        tintColor: NSColor?
    ) -> Result<NSImage, CmuxResolvedIconRenderFailure> {
        let rendered = NSImage(size: size)
        var didAddRepresentation = false

        for rasterScale in rasterScales {
            guard let bitmap = bitmapRepresentation(size: size, rasterScale: rasterScale) else {
                continue
            }
            bitmap.size = size
            guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                continue
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: size).fill(using: .copy)
            context.imageInterpolation = .high

            let drawRect = drawingRect(for: sourceImage.size, in: size)
            sourceImage.draw(
                in: drawRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            if let tintColor {
                tintColor.setFill()
                NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            }
            NSGraphicsContext.restoreGraphicsState()

            guard containsVisiblePixels(in: bitmap) else {
                continue
            }
            rendered.addRepresentation(bitmap)
            didAddRepresentation = true
        }

        guard didAddRepresentation else {
            return .failure(.blankOutput)
        }
        rendered.cacheMode = .never
        rendered.isTemplate = false
        return .success(rendered)
    }

    private func copiedImage(_ image: NSImage) -> NSImage {
        if let copy = image.copy() as? NSImage, copy !== image {
            copy.cacheMode = .never
            copy.isTemplate = false
            copy.recache()
            return copy
        }
        if let tiffRepresentation = image.tiffRepresentation,
           let decoded = NSImage(data: tiffRepresentation) {
            decoded.cacheMode = .never
            decoded.isTemplate = false
            decoded.recache()
            return decoded
        }
        return image
    }

    private func defaultTint(for source: CmuxResolvedIconSource) -> NSColor? {
        if case .systemSymbol = source {
            return .labelColor
        }
        return nil
    }

    private func bitmapRepresentation(size: NSSize, rasterScale: CGFloat) -> NSBitmapImageRep? {
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
