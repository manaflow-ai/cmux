public import Foundation
public import SwiftUI

/// Owns the transient presentation state for one window's command palette.
///
/// This is the editor/query/scroll half of the palette state that previously
/// lived as a blob of `@State` properties on `ContentView`: the search query,
/// the current input ``CommandPaletteMode``, the rename and workspace-description
/// drafts (plus the measured editor height), the selected result index and its
/// stable selection anchor, the pending scroll target, the queued activation and
/// text-selection behavior, the results revision counter, and the persisted
/// per-command usage history.
///
/// The host (`ContentView`) holds one instance and binds into it with
/// `@Bindable`. Visibility, escape suppression, and per-window selection live on
/// ``CommandPaletteWindowStore`` (one writer each); this model owns only the
/// window-agnostic transient editor state so each piece of palette state has a
/// single writer.
///
/// Usage-history persistence is byte-identical to the previous inline behavior:
/// the same JSON encoding under the same `UserDefaults` key
/// (``usageHistoryDefaultsKey``). The backing `UserDefaults` is injected so
/// tests can pass a scoped suite.
@MainActor
@Observable
public final class CommandPalettePresentationModel {
    /// Defaults key under which the per-command usage history is persisted.
    ///
    /// Frozen wire format: the value is a JSON-encoded
    /// `[String: CommandPaletteUsageEntry]` dictionary.
    public static let usageHistoryDefaultsKey = "commandPalette.commandUsage.v1"

    /// The current search query text.
    public var query: String = ""

    /// The palette's current input mode (command list, rename, or description).
    public var mode: CommandPaletteMode = .commands

    /// Draft text for the rename editor.
    public var renameDraft: String = ""

    /// Draft text for the workspace-description editor.
    public var workspaceDescriptionDraft: String = ""

    /// Measured height of the workspace-description multiline editor.
    public var workspaceDescriptionHeight: CGFloat

    /// Index of the currently selected result row.
    public var selectedResultIndex: Int = 0

    /// Stable command id the selection is anchored to, surviving result reorders.
    public var selectionAnchorCommandID: String?

    /// Result index the list should scroll to, or `nil` when no scroll is pending.
    public var scrollTargetIndex: Int?

    /// Scroll anchor for the pending scroll target.
    public var scrollTargetAnchor: UnitPoint?

    /// Activation queued while results are still resolving.
    public var pendingActivation: CommandPalettePendingActivation?

    /// Text-selection behavior to apply on the next editor focus.
    public var pendingTextSelectionBehavior: CommandPaletteTextSelectionBehavior?

    /// Monotonic revision bumped whenever the result list is recomputed.
    public var resultsRevision: UInt64 = 0

    /// Persisted per-command usage history backing the recency/frequency boost.
    public private(set) var usageHistoryByCommandId: [String: CommandPaletteUsageEntry] = [:]

    private let defaults: UserDefaults

    /// Creates a presentation model.
    ///
    /// - Parameters:
    ///   - defaultWorkspaceDescriptionHeight: initial measured editor height; the
    ///     host seeds this from the UI package's default minimum height.
    ///   - defaults: persistence store for the usage history (defaults to
    ///     `.standard`, matching the previous inline behavior).
    public init(
        defaultWorkspaceDescriptionHeight: CGFloat,
        defaults: UserDefaults = .standard
    ) {
        self.workspaceDescriptionHeight = defaultWorkspaceDescriptionHeight
        self.defaults = defaults
    }

    // MARK: Usage history

    /// Reloads the usage history from persistence, replacing the in-memory copy.
    public func refreshUsageHistory() {
        usageHistoryByCommandId = loadUsageHistory()
    }

    /// Records one run of `commandId`, bumping its count and last-used timestamp,
    /// then persists the updated history.
    ///
    /// - Parameter now: the timestamp to record; defaults to the current time so
    ///   the behavior matches the previous inline `Date().timeIntervalSince1970`.
    public func recordUsage(_ commandId: String, now: TimeInterval = Date().timeIntervalSince1970) {
        var history = usageHistoryByCommandId
        var entry = history[commandId] ?? CommandPaletteUsageEntry(useCount: 0, lastUsedAt: 0)
        entry.useCount += 1
        entry.lastUsedAt = now
        history[commandId] = entry
        usageHistoryByCommandId = history
        persistUsageHistory(history)
    }

    private func loadUsageHistory() -> [String: CommandPaletteUsageEntry] {
        guard let data = defaults.data(forKey: Self.usageHistoryDefaultsKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: CommandPaletteUsageEntry].self, from: data)) ?? [:]
    }

    private func persistUsageHistory(_ history: [String: CommandPaletteUsageEntry]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.usageHistoryDefaultsKey)
    }
}
