import AppKit

enum RenderableSystemSymbol {
    static let defaultWorkspaceGroupIcon = "folder.fill"
    static let defaultSurfaceTabIcon = "doc.text"

    static func trimmed(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func normalized(_ raw: String?) -> String? {
        guard let trimmed = trimmed(raw),
              isRenderable(trimmed) else {
            return nil
        }
        return trimmed
    }

    static func resolvedWorkspaceGroupIcon(explicit: String?, configured: String?) -> String {
        for candidate in [explicit, configured] {
            guard let normalized = normalized(candidate) else { continue }
            return normalized
        }
        return defaultWorkspaceGroupIcon
    }

    static func resolvedSurfaceTabIcon(_ raw: String?, fallback: String = defaultSurfaceTabIcon) -> String {
        normalized(raw)
            ?? normalized(fallback)
            ?? defaultSurfaceTabIcon
    }

    static func isRenderable(_ symbol: String) -> Bool {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
    }
}
