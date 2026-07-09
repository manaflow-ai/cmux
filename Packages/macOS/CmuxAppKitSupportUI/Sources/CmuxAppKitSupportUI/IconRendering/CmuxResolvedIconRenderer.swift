public import AppKit
public import Foundation

/// Renders small AppKit icons after resolving asset variants, template masks, and dynamic colors.
@MainActor
public final class CmuxResolvedIconRenderer {
    /// Creates an icon renderer.
    public init() {}

    /// Returns a non-template image rasterized for the supplied appearance.
    /// - Parameters:
    ///   - request: Icon render request.
    ///   - appearance: Appearance used to resolve dynamic colors and asset variants.
    /// - Returns: A copied, sized image, or `nil` when the source cannot be resolved.
    public func image(for request: CmuxResolvedIconRequest, appearance: NSAppearance) -> NSImage? {
        guard let imageSize = normalizedSize(request.size) else {
            return nil
        }
        let output = NSImage(size: imageSize)
        var didDraw = false
        appearance.performAsCurrentDrawingAppearance {
            guard let sourceImage = resolvedSourceImage(for: request) else {
                return
            }
            output.lockFocus()
            defer { output.unlockFocus() }

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
            didDraw = true
        }
        guard didDraw else {
            return nil
        }
        output.isTemplate = false
        return output
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
            image.isTemplate = true
            return image
        case .asset(let name, let bundle):
            guard let image = bundle.image(forResource: name) ?? NSImage(named: name) else {
                return nil
            }
            return copiedImage(image)
        case .image(let image):
            return copiedImage(image)
        }
    }

    private func copiedImage(_ image: NSImage) -> NSImage {
        (image.copy() as? NSImage) ?? image
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
