public import AppKit

/// Measures and caches the rendered width of sidebar shortcut-hint labels so
/// the trailing accessory slot can be sized without re-measuring text on every
/// layout pass.
///
/// The measurement cache is guarded by an `NSLock`: this is a pure stateless
/// utility whose only shared state is a width memo, so a lock is the faithful
/// minimal guard (no actor needed; callers are synchronous layout code).
// lint:allow namespace-type — pure stateless policy/value namespace lifted verbatim from ContentView; no natural receiver, modernization deferred.
public enum SidebarWorkspaceShortcutHintMetrics {
    // Immutable measurement font; NSFont is not Sendable but this constant is
    // never mutated and is only read under `lock` during measurement.
    nonisolated(unsafe) private static let measurementFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let minimumSlotWidth: CGFloat = 28
    private static let horizontalPadding: CGFloat = 12
    // Pure layout memo guarded by a lock; see type doc for the lock rationale.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedHintWidths: [String: CGFloat] = [:]
    #if DEBUG
    nonisolated(unsafe) private static var measurementCount = 0
    #endif

    /// Width of the trailing accessory slot for a hint `label`, accounting for
    /// the debug horizontal offset.
    public static func slotWidth(label: String?, debugXOffset: Double) -> CGFloat {
        guard let label else { return minimumSlotWidth }
        let positiveDebugInset = max(0, CGFloat(ShortcutHintDebugSettings.clamped(debugXOffset))) + 2
        return max(minimumSlotWidth, hintWidth(for: label) + positiveDebugInset)
    }

    /// Cached rendered width of a hint `label`.
    public static func hintWidth(for label: String) -> CGFloat {
        lock.lock()
        if let cached = cachedHintWidths[label] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let textWidth = (label as NSString).size(withAttributes: [.font: measurementFont]).width
        let measuredWidth = ceil(textWidth) + horizontalPadding

        lock.lock()
        cachedHintWidths[label] = measuredWidth
        #if DEBUG
        measurementCount += 1
        #endif
        lock.unlock()
        return measuredWidth
    }

    #if DEBUG
    /// Clears the measurement cache. DEBUG-only test hook.
    public static func resetCacheForTesting() {
        lock.lock()
        cachedHintWidths.removeAll()
        measurementCount = 0
        lock.unlock()
    }

    /// Number of text measurements performed since the last reset. DEBUG-only
    /// test hook proving the cache is hit.
    public static func measurementCountForTesting() -> Int {
        lock.lock()
        let count = measurementCount
        lock.unlock()
        return count
    }
    #endif
}
