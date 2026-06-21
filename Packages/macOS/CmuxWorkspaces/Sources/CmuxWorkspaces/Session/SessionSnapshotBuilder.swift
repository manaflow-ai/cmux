import Foundation

/// Pure window-assembly policy for the session snapshot and the session-autosave
/// fingerprint.
///
/// This is the value-typed half of the session-snapshot build path, lifted out
/// of `AppDelegate.buildSessionSnapshot` and `AppDelegate.sessionAutosaveFingerprint`.
/// The legacy bodies reached into the live registered-window list, every window's
/// `TabManager`/sidebar/`NSWindow` state, and the remote-tmux controller; that
/// reach now lives entirely in the app-side ``SessionSnapshotBuilding`` witness,
/// which flattens the live state into the value-typed inputs this service folds.
///
/// Two responsibilities, both pure transforms over already-flattened inputs so
/// the result is byte-identical to the god file:
///
/// 1. ``assembleWindows(from:maxWindows:)`` reproduces the build step that drops
///    a dedicated remote-tmux mirror window with no surviving workspaces, then
///    caps the window list. A dedicated remote window needs a live SSH control
///    connection and must not restore as an empty shell; if the user dragged
///    local workspaces into it those workspaces are kept (the host's per-window
///    snapshot already prunes the remote mirror workspaces), so the drop only
///    fires when the window ends up empty.
/// 2. ``fingerprint(over:maxWindows:)`` reproduces the autosave-skip fingerprint
///    over the window list: it folds the window count and each window's flattened
///    fingerprint fields into a `Hasher` in the exact legacy order, capped at the
///    same window limit. The autosave timer compares the previous and current
///    fingerprint and skips the write when they match, so any reordering would
///    silently change skip behavior.
///
/// Isolation: a stateless `Sendable` struct, not an actor and not a static-only
/// namespace. The methods are pure transforms over the value-typed inputs with
/// no mutable state to protect; the app holds one shared instance and forwards.
public struct SessionSnapshotBuilder: Sendable {
    /// Creates a snapshot builder.
    public init() {}

    /// Selects the window snapshots that survive into the persisted session
    /// snapshot, in the order the host supplied them.
    ///
    /// Drops any window whose host input is flagged
    /// ``SessionSnapshotWindowInput/dropsWhenEmptyDedicatedRemoteWindow`` (a
    /// dedicated remote-tmux window with no surviving workspaces), then caps the
    /// result at `maxWindows`. Byte-identical to the legacy
    /// `buildSessionSnapshot` `compactMap { ... }.prefix(maxWindowsPerSnapshot)`.
    ///
    /// - Parameters:
    ///   - inputs: the per-window snapshot inputs, already ordered by the host's
    ///     `sortedMainWindowContextsForSessionSnapshot` key-window ordering. Pass
    ///     a lazy sequence (e.g. `contexts.lazy.map { ... }`) so per-window
    ///     snapshots beyond the cap are not built, matching the legacy
    ///     `contexts.lazy.compactMap { ... }.prefix(maxWindows)`.
    ///   - maxWindows: the per-snapshot window cap
    ///     (`SessionPersistencePolicy.maxWindowsPerSnapshot`, 12).
    /// - Returns: the surviving per-window snapshot values, capped.
    public func assembleWindows<Inputs: Sequence, Window>(
        from inputs: Inputs,
        maxWindows: Int
    ) -> [Window] where Inputs.Element == SessionSnapshotWindowInput<Window> {
        Array(
            inputs.lazy
                .compactMap { input -> Window? in
                    input.dropsWhenEmptyDedicatedRemoteWindow ? nil : input.snapshot
                }
                .prefix(maxWindows)
        )
    }

    /// Folds the per-window autosave-fingerprint fields into a single `Int`,
    /// matching the legacy `sessionAutosaveFingerprint` window-list folding.
    ///
    /// Combines the full `windowCount` first, then for each capped window combines
    /// the window id, the window's `TabManager` fingerprint, the sidebar
    /// visibility, the quantized sidebar width, the sidebar-selection tag, and the
    /// frame fold in the exact legacy order. The host passes the full window count
    /// separately and supplies ONLY the windows that survive the cap (the legacy
    /// body read `contexts.count` for the count but only did per-window work for
    /// `contexts.prefix(maxWindows)`), so this body never re-derives the count or
    /// the cap; it only folds.
    ///
    /// - Parameters:
    ///   - cappedInputs: the per-window fingerprint inputs for the windows that
    ///     survive the cap, already sorted by the host by `windowId.uuidString`
    ///     ascending and already truncated to `maxWindows`.
    ///   - windowCount: the full registered-window count, before the cap (legacy
    ///     `contexts.count`).
    /// - Returns: the folded fingerprint.
    public func fingerprint(
        cappedInputs: [SessionSnapshotFingerprintWindowInput],
        windowCount: Int
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(windowCount)

        for input in cappedInputs {
            hasher.combine(input.windowId)
            hasher.combine(input.tabManagerFingerprint)
            hasher.combine(input.sidebarIsVisible)
            hasher.combine(input.quantizedSidebarWidth)
            hasher.combine(input.sidebarSelectionTag)
            input.foldFrame(&hasher)
        }

        return hasher.finalize()
    }
}
