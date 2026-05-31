import AppKit

private final class RenderableSystemSymbolCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    func value(for symbol: String, compute: () -> Bool) -> Bool {
        lock.lock()
        if let cached = values[symbol] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = compute()

        lock.lock()
        values[symbol] = resolved
        lock.unlock()
        return resolved
    }

    #if DEBUG
    func removeAll() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }
    #endif
}

enum RenderableSystemSymbol {
    static let defaultWorkspaceGroupIcon = "folder.fill"
    static let defaultSurfaceTabIcon = "doc.text"
    private static let cache = RenderableSystemSymbolCache()

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
        cache.value(for: symbol) {
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        }
    }

    #if DEBUG
    static func resetRenderabilityCacheForTesting() {
        cache.removeAll()
    }
    #endif
}
