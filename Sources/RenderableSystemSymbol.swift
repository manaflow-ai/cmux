import AppKit
import CmuxFoundation
import SwiftUI

enum RenderableSystemSymbol {
    static let defaultWorkspaceGroupIcon = "folder.fill"
    static let defaultSurfaceTabIcon = "doc.text"
    private static let minimumRasterPointSize: CGFloat = 1
    private static let negativeRenderabilityRetryInterval: TimeInterval = 60
    private static let renderabilityCacheLimit = 512
    private static let appKitImageCacheLimit = 256
    @MainActor
    private static var renderabilityCache = RenderabilityCache(
        limit: renderabilityCacheLimit,
        negativeRetryInterval: negativeRenderabilityRetryInterval,
        resolve: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    )
    @MainActor
    private static var appKitImageCache: [AppKitImageCacheKey: NSImage] = [:]
    @MainActor
    private static var appKitImageCacheInsertionOrder: [AppKitImageCacheKey] = []

    struct RenderabilityCache {
        private let limit: Int
        private let negativeRetryInterval: TimeInterval
        private let now: () -> Date
        private let resolve: (String) -> Bool
        private var values: [String: Bool] = [:]
        private var timestamps: [String: Date] = [:]
        private var insertionOrder: [String] = []

        init(
            limit: Int,
            negativeRetryInterval: TimeInterval,
            now: @escaping () -> Date = Date.init,
            resolve: @escaping (String) -> Bool
        ) {
            self.limit = limit
            self.negativeRetryInterval = negativeRetryInterval
            self.now = now
            self.resolve = resolve
        }

        mutating func isRenderable(_ symbol: String) -> Bool {
            if let cached = cachedRenderability(symbol) {
                return cached
            }
            let resolved = resolve(symbol)
            cacheRenderability(resolved, for: symbol)
            return resolved
        }

        mutating func cacheRenderability(_ isRenderable: Bool, for symbol: String) {
            if values[symbol] == nil {
                insertionOrder.append(symbol)
            }
            values[symbol] = isRenderable
            timestamps[symbol] = now()
            while insertionOrder.count > limit {
                let evictedSymbol = insertionOrder.removeFirst()
                values.removeValue(forKey: evictedSymbol)
                timestamps.removeValue(forKey: evictedSymbol)
            }
        }

        mutating func reset() {
            values.removeAll()
            timestamps.removeAll()
            insertionOrder.removeAll()
        }

        private mutating func cachedRenderability(_ symbol: String) -> Bool? {
            if let cached = values[symbol] {
                if cached || !shouldRetryNegativeRenderability(symbol) {
                    return cached
                }
                removeCachedRenderability(for: symbol)
            }
            return nil
        }

        private func shouldRetryNegativeRenderability(_ symbol: String) -> Bool {
            guard values[symbol] == false,
                  let timestamp = timestamps[symbol] else {
                return false
            }
            return now().timeIntervalSince(timestamp) >= negativeRetryInterval
        }

        private mutating func removeCachedRenderability(for symbol: String) {
            values.removeValue(forKey: symbol)
            timestamps.removeValue(forKey: symbol)
            insertionOrder.removeAll { $0 == symbol }
        }
    }

    private struct AppKitImageCacheKey: Hashable {
        let systemName: String
        let rasterSize: CGFloat
        let weightRawValue: CGFloat
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
        guard let trimmed = trimmed(raw),
              isRenderable(trimmed) else {
            return nil
        }
        return trimmed
    }

    @MainActor
    static func resolvedWorkspaceGroupIcon(explicit: String?, configured: String?) -> String {
        for candidate in [explicit, configured] {
            guard let normalized = normalized(candidate) else { continue }
            return normalized
        }
        return defaultWorkspaceGroupIcon
    }

    @MainActor
    static func resolvedSurfaceTabIcon(_ raw: String?, fallback: String = defaultSurfaceTabIcon) -> String {
        normalized(raw)
            ?? normalized(fallback)
            ?? defaultSurfaceTabIcon
    }

    @MainActor
    static func isRenderable(_ symbol: String) -> Bool {
        renderabilityCache.isRenderable(symbol)
    }

    static func clampedRasterPointSize(_ pointSize: CGFloat) -> CGFloat {
        guard pointSize.isFinite else {
            return minimumRasterPointSize
        }
        return max(minimumRasterPointSize, pointSize)
    }

    static func resolvedRasterPointSize(
        _ pointSize: CGFloat,
        globalFontPercent: Int,
        appliesGlobalFontMagnification: Bool
    ) -> CGFloat {
        let rasterSize = clampedRasterPointSize(pointSize)
        guard appliesGlobalFontMagnification else {
            return rasterSize
        }
        return GlobalFontMagnification.scaledSize(rasterSize, percent: globalFontPercent)
    }

    @MainActor
    static func configuredAppKitImage(
        systemName: String,
        pointSize: CGFloat,
        weight: Font.Weight? = nil
    ) -> NSImage? {
        let rasterSize = clampedRasterPointSize(pointSize)
        let fontWeight = nsFontWeight(for: weight)
        let cacheKey = AppKitImageCacheKey(
            systemName: systemName,
            rasterSize: rasterSize,
            weightRawValue: fontWeight.rawValue
        )
        if let cached = appKitImageCache[cacheKey] {
            return cached
        }
        if !renderabilityCache.isRenderable(systemName) {
            return nil
        }
        guard let baseImage = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            renderabilityCache.cacheRenderability(false, for: systemName)
            return nil
        }
        renderabilityCache.cacheRenderability(true, for: systemName)
        let configuration = NSImage.SymbolConfiguration(
            pointSize: rasterSize,
            weight: fontWeight
        )
        let configuredImage = baseImage.withSymbolConfiguration(configuration) ?? baseImage
        let image = (configuredImage.copy() as? NSImage) ?? configuredImage
        image.isTemplate = true
        image.size = symbolImageSize(configuredImage.size, fallbackDimension: rasterSize)
        appKitImageCache[cacheKey] = image
        appKitImageCacheInsertionOrder.append(cacheKey)
        while appKitImageCacheInsertionOrder.count > appKitImageCacheLimit {
            let evictedKey = appKitImageCacheInsertionOrder.removeFirst()
            appKitImageCache.removeValue(forKey: evictedKey)
        }
        return image
    }

    static func symbolImageSize(_ naturalSize: NSSize, fallbackDimension: CGFloat) -> NSSize {
        let fallbackDimension = clampedRasterPointSize(fallbackDimension)
        guard naturalSize.width.isFinite,
              naturalSize.height.isFinite,
              naturalSize.width > 0,
              naturalSize.height > 0 else {
            return NSSize(width: fallbackDimension, height: fallbackDimension)
        }
        return naturalSize
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
        renderabilityCache.reset()
        appKitImageCache.removeAll()
        appKitImageCacheInsertionOrder.removeAll()
    }
    #endif
}

struct CmuxSystemSymbolImage: View {
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    let systemName: String
    let pointSize: CGFloat
    var weight: Font.Weight?
    var alignment: Alignment = .center
    var appliesGlobalFontMagnification = false

    init(
        systemName: String,
        pointSize: CGFloat,
        weight: Font.Weight? = nil,
        alignment: Alignment = .center,
        appliesGlobalFontMagnification: Bool = false
    ) {
        self.systemName = systemName
        self.pointSize = pointSize
        self.weight = weight
        self.alignment = alignment
        self.appliesGlobalFontMagnification = appliesGlobalFontMagnification
    }

    init(
        magnified systemName: String,
        pointSize: CGFloat,
        weight: Font.Weight? = nil,
        alignment: Alignment = .center
    ) {
        self.init(
            systemName: systemName,
            pointSize: pointSize,
            weight: weight,
            alignment: alignment,
            appliesGlobalFontMagnification: true
        )
    }

    var body: some View {
        let rasterSize = RenderableSystemSymbol.resolvedRasterPointSize(
            pointSize,
            globalFontPercent: globalFontPercent,
            appliesGlobalFontMagnification: appliesGlobalFontMagnification
        )
        if let image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: systemName,
            pointSize: rasterSize,
            weight: weight
        ) {
            Image(nsImage: image)
                .renderingMode(.template)
                .frame(width: rasterSize, height: rasterSize, alignment: alignment)
        } else {
            Color.clear
                .frame(width: rasterSize, height: rasterSize, alignment: alignment)
                .accessibilityHidden(true)
        }
    }
}
