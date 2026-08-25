import AppKit
import SwiftUI

/// Validates and materializes SF Symbols before SwiftUI or AppKit layout.
enum RenderableSystemSymbol {
    static let defaultWorkspaceGroupIcon = "folder.fill"
    static let defaultSurfaceTabIcon = "doc.text"

    private static let minimumPointSize: CGFloat = 1
    private static let renderabilityCacheLimit = 512
    private static let imageCacheLimit = 256

    @MainActor
    private static var renderabilityCache: [String: Bool] = [:]
    @MainActor
    private static var renderabilityInsertionOrder: [String] = []
    @MainActor
    private static var imageCache: [AppKitImageCacheKey: NSImage] = [:]
    @MainActor
    private static var imageInsertionOrder: [AppKitImageCacheKey] = []

    private struct AppKitImageCacheKey: Hashable {
        let systemName: String
        let pointSize: CGFloat
        let weight: CGFloat
    }

    static func trimmed(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    @MainActor
    static func normalized(_ raw: String?) -> String? {
        guard let trimmed = trimmed(raw), isRenderable(trimmed) else {
            return nil
        }
        return trimmed
    }

    @MainActor
    static func resolvedWorkspaceGroupIcon(explicit: String?, configured: String?) -> String {
        for candidate in [explicit, configured] {
            if let normalized = normalized(candidate) {
                return normalized
            }
        }
        return defaultWorkspaceGroupIcon
    }

    @MainActor
    static func resolvedSurfaceTabIcon(_ raw: String?, fallback: String = defaultSurfaceTabIcon) -> String {
        normalized(raw) ?? normalized(fallback) ?? defaultSurfaceTabIcon
    }

    /// Resolves a symbol without permanently caching transient failures.
    @MainActor
    static func isRenderable(_ symbol: String) -> Bool {
        if renderabilityCache[symbol] == true {
            return true
        }
        guard NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else {
            renderabilityCache.removeValue(forKey: symbol)
            renderabilityInsertionOrder.removeAll { $0 == symbol }
            return false
        }
        cacheRenderable(symbol)
        return true
    }

    /// Returns a concrete template bitmap for callers that still apply a SwiftUI tint.
    @MainActor
    static func configuredAppKitImage(
        systemName: String,
        pointSize: CGFloat,
        weight: Font.Weight? = nil
    ) -> NSImage? {
        let pointSize = max(minimumPointSize, pointSize.isFinite ? pointSize : minimumPointSize)
        let fontWeight = nsFontWeight(for: weight)
        let key = AppKitImageCacheKey(
            systemName: systemName,
            pointSize: pointSize,
            weight: fontWeight.rawValue
        )
        if let cached = imageCache[key] {
            return cached
        }
        guard isRenderable(systemName),
              let baseImage = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: fontWeight)
        let configured = baseImage.withSymbolConfiguration(configuration) ?? baseImage
        guard let image = materializedTemplateImage(configured, pointSize: pointSize) else {
            return nil
        }
        imageCache[key] = image
        imageInsertionOrder.append(key)
        while imageInsertionOrder.count > imageCacheLimit {
            let evicted = imageInsertionOrder.removeFirst()
            imageCache.removeValue(forKey: evicted)
        }
        return image
    }

    @MainActor
    private static func materializedTemplateImage(_ source: NSImage, pointSize: CGFloat) -> NSImage? {
        guard let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua) else {
            return nil
        }
        let naturalSize = source.size
        let size: NSSize
        if naturalSize.width.isFinite, naturalSize.height.isFinite,
           naturalSize.width > 0, naturalSize.height > 0 {
            let scale = pointSize / max(naturalSize.width, naturalSize.height)
            size = NSSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
        } else {
            size = NSSize(width: pointSize, height: pointSize)
        }

        let image = NSImage(size: size)
        let drawableSource = (source.copy() as? NSImage) ?? source
        drawableSource.isTemplate = false
        var hasVisiblePixels = false
        appearance.performAsCurrentDrawingAppearance {
            for scale in [CGFloat(2), CGFloat(1)] {
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: max(1, Int(ceil(size.width * scale))),
                    pixelsHigh: max(1, Int(ceil(size.height * scale))),
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ) else {
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
                drawableSource.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                guard containsVisiblePixels(in: bitmap) else { continue }
                image.addRepresentation(bitmap)
                hasVisiblePixels = true
            }
        }
        guard hasVisiblePixels else { return nil }
        image.cacheMode = .never
        image.isTemplate = true
        return image
    }

    private static func containsVisiblePixels(in bitmap: NSBitmapImageRep) -> Bool {
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                    return true
                }
            }
        }
        return false
    }

    @MainActor
    private static func cacheRenderable(_ symbol: String) {
        guard renderabilityCache[symbol] == nil else { return }
        renderabilityCache[symbol] = true
        renderabilityInsertionOrder.append(symbol)
        while renderabilityInsertionOrder.count > renderabilityCacheLimit {
            let evicted = renderabilityInsertionOrder.removeFirst()
            renderabilityCache.removeValue(forKey: evicted)
        }
    }

    private static func nsFontWeight(for weight: Font.Weight?) -> NSFont.Weight {
        guard let weight else { return .regular }
        if weight == .ultraLight { return .ultraLight }
        if weight == .thin { return .thin }
        if weight == .light { return .light }
        if weight == .medium { return .medium }
        if weight == .semibold { return .semibold }
        if weight == .bold { return .bold }
        if weight == .heavy { return .heavy }
        if weight == .black { return .black }
        return .regular
    }

    #if DEBUG
    @MainActor
    static func resetRenderabilityCacheForTesting() {
        renderabilityCache.removeAll()
        renderabilityInsertionOrder.removeAll()
        imageCache.removeAll()
        imageInsertionOrder.removeAll()
    }
    #endif
}
