import AppKit

enum RenderableWorkspaceGroupIcon: Equatable {
    case systemSymbol(String)
    case emoji(String)

    var rawValue: String {
        switch self {
        case .systemSymbol(let symbol), .emoji(let symbol):
            return symbol
        }
    }
}

enum RenderableSystemSymbol {
    static let defaultWorkspaceGroupIcon = "folder.fill"
    static let defaultSurfaceTabIcon = "doc.text"
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
    static func normalizedWorkspaceGroupIcon(_ raw: String?) -> String? {
        guard let trimmed = trimmed(raw) else { return nil }
        if let emoji = normalizedEmoji(trimmed) {
            return emoji
        }
        return normalized(trimmed)
    }

    @MainActor
    static func resolvedWorkspaceGroupIconValue(explicit: String?, configured: String?) -> RenderableWorkspaceGroupIcon {
        for candidate in [explicit, configured] {
            guard let normalized = normalizedWorkspaceGroupIcon(candidate) else { continue }
            if let emoji = normalizedEmoji(normalized) {
                return .emoji(emoji)
            }
            return .systemSymbol(normalized)
        }
        return .systemSymbol(defaultWorkspaceGroupIcon)
    }

    @MainActor
    static func resolvedWorkspaceGroupIcon(explicit: String?, configured: String?) -> String {
        resolvedWorkspaceGroupIconValue(explicit: explicit, configured: configured).rawValue
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

    static func normalizedEmoji(_ raw: String?) -> String? {
        guard let trimmed = trimmed(raw),
              trimmed.count == 1,
              let character = trimmed.first else {
            return nil
        }
        let scalars = character.unicodeScalars
        let containsEmoji = scalars.contains { $0.properties.isEmoji }
        let containsEmojiPresentation = scalars.contains {
            $0.properties.isEmojiPresentation ||
                $0.properties.isEmojiModifier ||
                $0.properties.isEmojiModifierBase ||
                $0.value == 0xFE0F
        }
        let isASCIIOnly = scalars.allSatisfy { $0.value < 128 }
        guard containsEmoji,
              containsEmojiPresentation || !isASCIIOnly else {
            return nil
        }
        return String(character)
    }

    #if DEBUG
    @MainActor
    static func resetRenderabilityCacheForTesting() {
        renderabilityCache.removeAll()
    }
    #endif
}
