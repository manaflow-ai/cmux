public import Foundation
public import Observation

/// Owns the per-window command-palette state for every main window.
///
/// The store is keyed by window identifier (`UUID`) and holds the visibility,
/// pending-open, escape-suppression, selection, and debug-snapshot state that
/// the command-palette flows mutate. The app target resolves `NSWindow` values
/// to identifiers and forwards into this store; all window-agnostic state and
/// the grace/prune/suppression timing logic live here.
///
/// Timing is expressed in `ProcessInfo.processInfo.systemUptime` seconds, passed
/// in by callers as `now` so the logic stays pure and testable.
@MainActor
@Observable
public final class CommandPaletteWindowStore {
    /// Grace window during which a recent palette request is still considered fresh.
    public static let requestGraceInterval: TimeInterval = 1.25
    /// Maximum age before a pending-open request is pruned as stale.
    public static let pendingOpenMaxAge: TimeInterval = 8.0
    /// Window during which a suppressed escape key-up is consumed.
    public static let escapeSuppressionInterval: TimeInterval = 0.35

    private var visibilityByWindowId: [UUID: Bool] = [:]
    private var pendingOpenByWindowId: [UUID: Bool] = [:]
    private var recentRequestAtByWindowId: [UUID: TimeInterval] = [:]
    private var escapeSuppressionByWindowId: Set<UUID> = []
    private var escapeSuppressionStartedAtByWindowId: [UUID: TimeInterval] = [:]
    private var selectionByWindowId: [UUID: Int] = [:]
    private var snapshotByWindowId: [UUID: CommandPaletteDebugSnapshot] = [:]

    /// Creates an empty store.
    public init() {}

    // MARK: Registration / teardown

    /// Seeds the baseline palette state for a newly registered window.
    public func registerWindow(_ windowId: UUID) {
        visibilityByWindowId[windowId] = false
        selectionByWindowId[windowId] = 0
        snapshotByWindowId[windowId] = .empty
    }

    /// Removes every piece of palette state for a window being torn down.
    public func removeWindow(_ windowId: UUID) {
        visibilityByWindowId.removeValue(forKey: windowId)
        pendingOpenByWindowId.removeValue(forKey: windowId)
        recentRequestAtByWindowId.removeValue(forKey: windowId)
        escapeSuppressionByWindowId.remove(windowId)
        escapeSuppressionStartedAtByWindowId.removeValue(forKey: windowId)
        selectionByWindowId.removeValue(forKey: windowId)
        snapshotByWindowId.removeValue(forKey: windowId)
    }

    // MARK: Pending-open

    /// Marks a window as having requested a palette open at `now`.
    public func markOpenRequested(_ windowId: UUID, now: TimeInterval) {
        pendingOpenByWindowId[windowId] = true
        recentRequestAtByWindowId[windowId] = now
    }

    /// Clears the pending-open request for a window.
    public func clearPendingOpen(_ windowId: UUID) {
        pendingOpenByWindowId.removeValue(forKey: windowId)
        recentRequestAtByWindowId.removeValue(forKey: windowId)
    }

    /// The outcome of pruning a single stale pending-open entry, for debug logging.
    public enum PrunedPendingOpen: Sendable {
        /// The entry was pruned because it had no recorded request timestamp.
        case missingTimestamp(windowId: UUID)
        /// The entry was pruned because it exceeded `pendingOpenMaxAge`.
        case stale(windowId: UUID, age: TimeInterval)
    }

    /// Prunes pending-open entries older than `pendingOpenMaxAge`.
    ///
    /// - Returns: the entries pruned, so the caller can emit debug logs that
    ///   match the previous inline behavior.
    @discardableResult
    public func pruneExpiredPendingOpenStates(now: TimeInterval) -> [PrunedPendingOpen] {
        var pruned: [PrunedPendingOpen] = []
        for windowId in Array(pendingOpenByWindowId.keys) {
            guard pendingOpenByWindowId[windowId] == true else { continue }
            guard let requestedAt = recentRequestAtByWindowId[windowId] else {
                pendingOpenByWindowId.removeValue(forKey: windowId)
                pruned.append(.missingTimestamp(windowId: windowId))
                continue
            }
            let age = now - requestedAt
            guard age > Self.pendingOpenMaxAge else { continue }
            pendingOpenByWindowId.removeValue(forKey: windowId)
            recentRequestAtByWindowId.removeValue(forKey: windowId)
            pruned.append(.stale(windowId: windowId, age: age))
        }
        return pruned
    }

    /// Whether a window has a live pending-open request after pruning stale entries.
    public func isPendingOpen(_ windowId: UUID, now: TimeInterval) -> Bool {
        _ = pruneExpiredPendingOpenStates(now: now)
        return pendingOpenByWindowId[windowId] == true
    }

    /// Raw pending-open flag without pruning.
    public func isPendingOpenRaw(_ windowId: UUID) -> Bool {
        pendingOpenByWindowId[windowId] == true
    }

    /// The age of a recent, still-fresh palette request, or `nil` when none applies.
    public func recentRequestAge(_ windowId: UUID, now: TimeInterval) -> TimeInterval? {
        _ = pruneExpiredPendingOpenStates(now: now)
        guard pendingOpenByWindowId[windowId] == true else {
            recentRequestAtByWindowId.removeValue(forKey: windowId)
            return nil
        }
        guard let startedAt = recentRequestAtByWindowId[windowId] else {
            pendingOpenByWindowId.removeValue(forKey: windowId)
            return nil
        }
        let age = now - startedAt
        if age <= Self.requestGraceInterval {
            return age
        }
        return nil
    }

    /// The first window id with a live pending-open request, if any.
    public func firstPendingOpenWindowId() -> UUID? {
        pendingOpenByWindowId.first(where: { $0.value })?.key
    }

    /// Test seam: forces a window's pending-open request to a given age.
    public func setPendingOpenAge(_ windowId: UUID, now: TimeInterval, age: TimeInterval) {
        pendingOpenByWindowId[windowId] = true
        recentRequestAtByWindowId[windowId] = now - max(age, 0)
    }

    // MARK: Escape suppression

    /// Begins escape suppression for a window at `now`.
    public func beginEscapeSuppression(_ windowId: UUID, now: TimeInterval) {
        escapeSuppressionByWindowId.insert(windowId)
        escapeSuppressionStartedAtByWindowId[windowId] = now
    }

    /// Ends escape suppression for a window.
    public func endEscapeSuppression(_ windowId: UUID) {
        escapeSuppressionByWindowId.remove(windowId)
        escapeSuppressionStartedAtByWindowId.removeValue(forKey: windowId)
    }

    /// Whether a suppressed escape should be consumed for a window at `now`.
    ///
    /// When suppression has expired the entry is cleaned up as a fallback for a
    /// lost key-up, matching the previous inline behavior.
    public func shouldConsumeSuppressedEscape(_ windowId: UUID, now: TimeInterval) -> Bool {
        guard escapeSuppressionByWindowId.contains(windowId) else { return false }
        let startedAt = escapeSuppressionStartedAtByWindowId[windowId] ?? 0
        if now - startedAt <= Self.escapeSuppressionInterval {
            return true
        }
        endEscapeSuppression(windowId)
        return false
    }

    /// Clears escape suppression for every window (fallback when no window resolves).
    public func clearAllEscapeSuppression() {
        escapeSuppressionByWindowId.removeAll()
        escapeSuppressionStartedAtByWindowId.removeAll()
    }

    // MARK: Visibility

    /// The result of a visibility update, surfacing the prior value and whether
    /// the in-flight pending-open request was retained.
    public struct VisibilityUpdate: Sendable {
        /// Whether the palette was visible before this update.
        public let wasVisible: Bool
        /// Whether a pending-open request was retained despite a false→false update.
        public let retainedPending: Bool
    }

    /// Updates a window's visibility, clearing pending-open state on open/close.
    ///
    /// Opening (`false`→`true`) and closing (`true`→`false`) both resolve any
    /// pending-open request. Repeated `false` updates are ignored so a stale
    /// sync cannot erase an in-flight open request.
    @discardableResult
    public func setVisible(_ visible: Bool, for windowId: UUID) -> VisibilityUpdate {
        let wasVisible = visibilityByWindowId.updateValue(visible, forKey: windowId) ?? false
        if visible || wasVisible {
            pendingOpenByWindowId.removeValue(forKey: windowId)
            recentRequestAtByWindowId.removeValue(forKey: windowId)
        }
        let retainedPending = !visible && !wasVisible && pendingOpenByWindowId[windowId] == true
        return VisibilityUpdate(wasVisible: wasVisible, retainedPending: retainedPending)
    }

    /// Whether the palette is marked visible for a window.
    public func isVisible(_ windowId: UUID) -> Bool {
        visibilityByWindowId[windowId] ?? false
    }

    /// The first window id with the palette currently visible, if any.
    public func firstVisibleWindowId() -> UUID? {
        visibilityByWindowId.first(where: { $0.value })?.key
    }

    // MARK: Selection

    /// Sets the clamped selection index for a window.
    public func setSelectionIndex(_ index: Int, for windowId: UUID) {
        selectionByWindowId[windowId] = max(0, index)
    }

    /// The selection index for a window, defaulting to zero.
    public func selectionIndex(_ windowId: UUID) -> Int {
        selectionByWindowId[windowId] ?? 0
    }

    // MARK: Snapshot

    /// Stores the debug snapshot for a window.
    public func setSnapshot(_ snapshot: CommandPaletteDebugSnapshot, for windowId: UUID) {
        snapshotByWindowId[windowId] = snapshot
    }

    /// The debug snapshot for a window, defaulting to empty.
    public func snapshot(_ windowId: UUID) -> CommandPaletteDebugSnapshot {
        snapshotByWindowId[windowId] ?? .empty
    }
}
