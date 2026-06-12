import AppKit

enum RenderableSystemSymbol {
    private static let defaultWorkspaceGroupIcon = "folder.fill"
    private static let defaultSurfaceTabIcon = "doc.text"
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
    private static func isRenderable(_ symbol: String) -> Bool {
        if let cached = renderabilityCache[symbol] {
            return cached
        }
        let resolved = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        renderabilityCache[symbol] = resolved
        return resolved
    }
}
