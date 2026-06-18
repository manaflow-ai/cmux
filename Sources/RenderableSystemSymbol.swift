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

    #if DEBUG
    @MainActor
    static func resetRenderabilityCacheForTesting() {
        renderabilityCache.removeAll()
    }
    #endif
}

extension Image {
    /// Keeps a positive symbol frame while avoiding the blank-prone resizable SF Symbol rasterizer.
    func cmuxSymbolRasterSize(
        _ pointSize: CGFloat,
        weight: Font.Weight? = nil,
        alignment: Alignment = .center
    ) -> some View {
        let rasterSize = RenderableSystemSymbol.clampedRasterPointSize(pointSize)
        let systemFont: Font = weight.map { .system(size: rasterSize, weight: $0) } ?? .system(size: rasterSize)
        return font(systemFont)
            .frame(width: rasterSize, height: rasterSize, alignment: alignment)
    }
}
