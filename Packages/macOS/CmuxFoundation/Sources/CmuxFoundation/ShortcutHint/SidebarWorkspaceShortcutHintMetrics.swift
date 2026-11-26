public import AppKit

/// Measures and caches the rendered width of sidebar shortcut-hint labels so
/// the trailing accessory slot can be sized without re-measuring text on every
/// layout pass.
///
/// The process-wide measurement cache is guarded by an `NSLock`: this is a pure
/// stateless utility whose only shared state is a width memo, so a lock is the
/// faithful minimal guard (no actor needed; callers are synchronous layout
/// code). Instances are interchangeable; they all share the same memo.
public struct SidebarWorkspaceShortcutHintMetrics {
    private static let minimumSlotWidth: CGFloat = 28
    private static let horizontalPadding: CGFloat = 12
    // Pure layout memo guarded by a lock; see type doc for the lock rationale.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedHintWidths: [String: CGFloat] = [:]
    #if DEBUG
    nonisolated(unsafe) private static var measurementCount = 0
    #endif

    public init() {}

    /// Width of the trailing accessory slot for a hint `label`, accounting for
    /// the debug horizontal offset.
    public func slotWidth(label: String?, debugXOffset: Double) -> CGFloat {
        guard let label else { return Self.minimumSlotWidth }
        let positiveDebugInset = max(0, CGFloat(ShortcutHintDebugSettings.clamped(debugXOffset))) + 2
        return max(Self.minimumSlotWidth, hintWidth(for: label) + positiveDebugInset)
    }

    /// Cached rendered width of a hint `label`.
    public func hintWidth(for label: String) -> CGFloat {
        let percent = GlobalFontMagnification.storedPercent
        let cacheKey = "\(percent)\u{0}\(label)"
        Self.lock.lock()
        if let cached = Self.cachedHintWidths[cacheKey] {
            Self.lock.unlock()
            return cached
        }
        Self.lock.unlock()

        let pointSize = max(1, 10 * CGFloat(percent) / CGFloat(GlobalFontMagnification.defaultPercent))
        let measurementFont = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        let textWidth = (label as NSString).size(withAttributes: [.font: measurementFont]).width
        let measuredWidth = ceil(textWidth) + Self.horizontalPadding

        Self.lock.lock()
        Self.cachedHintWidths[cacheKey] = measuredWidth
        #if DEBUG
        Self.measurementCount += 1
        #endif
        Self.lock.unlock()
        return measuredWidth
    }

    #if DEBUG
    /// Clears the measurement cache. DEBUG-only test hook.
    public func resetCacheForTesting() {
        Self.lock.lock()
        Self.cachedHintWidths.removeAll()
        Self.measurementCount = 0
        Self.lock.unlock()
    }

    /// Number of text measurements performed since the last reset. DEBUG-only
    /// test hook proving the cache is hit.
    public func measurementCountForTesting() -> Int {
        Self.lock.lock()
        let count = Self.measurementCount
        Self.lock.unlock()
        return count
    }
    #endif
}
