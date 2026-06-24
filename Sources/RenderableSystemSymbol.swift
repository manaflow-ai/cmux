import AppKit
import SwiftUI

enum RenderableSystemSymbol {
    static let defaultWorkspaceGroupIcon = "folder.fill"
    static let defaultSurfaceTabIcon = "doc.text"
    private static let minimumRasterPointSize: CGFloat = 1
    @MainActor
    private static var renderabilityCache: [String: Bool] = [:]

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
        if let cached = renderabilityCache[symbol] {
            return cached
        }
        let resolved = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        renderabilityCache[symbol] = resolved
        return resolved
    }

    static func clampedRasterPointSize(_ pointSize: CGFloat) -> CGFloat {
        guard pointSize.isFinite else {
            return minimumRasterPointSize
        }
        return max(minimumRasterPointSize, pointSize)
    }

    @MainActor
    static func configuredAppKitImage(
        systemName: String,
        pointSize: CGFloat,
        weight: Font.Weight? = nil
    ) -> NSImage? {
        let rasterSize = clampedRasterPointSize(pointSize)
        guard let baseImage = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(
            pointSize: rasterSize,
            weight: nsFontWeight(for: weight)
        )
        let configuredImage = baseImage.withSymbolConfiguration(configuration) ?? baseImage
        let image = (configuredImage.copy() as? NSImage) ?? configuredImage
        image.isTemplate = true
        image.size = NSSize(width: rasterSize, height: rasterSize)
        return image
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
    }
    #endif
}

struct CmuxSystemSymbolImage: View {
    let systemName: String
    let pointSize: CGFloat
    var weight: Font.Weight?
    var alignment: Alignment = .center

    var body: some View {
        let rasterSize = RenderableSystemSymbol.clampedRasterPointSize(pointSize)
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
