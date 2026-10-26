import CmuxSettings
import SwiftUI

/// Lazy inline rendering of the shortcut-recorder rows that match the search
/// query. It keeps the current active
/// list height as a minimum while inactive so app activation changes cannot
/// shrink the Settings document while off-screen rows are de-realized.
///
/// Matches are taken when the query changes, not on every binding change, so a
/// row edited under a filter (unbound, rebound) stays put with its Restore button.
@MainActor
struct ShortcutListStableLazyView: View {
    /// Keep a burst of keystrokes from rebuilding the virtualized row tree for
    /// every character. Matching is still immediate when the query is cleared.
    private static let searchDebounce: Duration = .milliseconds(80)

    @Environment(\.controlActiveState) private var controlActiveState

    let model: ShortcutListModel
    let query: ShortcutListSearchQuery
    @State private var measuredHeight: CGFloat = 0
    @State private var lastReportedHeight: CGFloat = 0
    /// Actions matching `query` when it last changed, or `nil` when unfiltered.
    @State private var matchedActions: [ShortcutAction]?
    @State private var matchedActionsQuery: ShortcutListSearchQuery?
    @State private var searchIndex: ShortcutListSearchIndex?
    @State private var searchIndexRevision = 0
    @State private var preserveShownOnIndexRefresh = false
    @State private var shownActionsForIndexRefresh: [ShortcutAction] = []

    var body: some View {
        let actions = matchedActions ?? ShortcutAction.settingsVisibleActions
        ShortcutListRows(entries: rowEntries(for: actions), revision: searchIndexRevision)
            .equatable()
        .background {
            ShortcutListHeightReader { height in
                updateMeasuredHeight(to: height)
            }
        }
        .frame(minHeight: measuredHeight, alignment: .top)
        .onChange(of: query) { _, _ in
            // A new text query must replace the prior result set. Binding
            // refreshes set this flag back to true after rebuilding the index.
            preserveShownOnIndexRefresh = false
        }
        // A binding edit can give another action the searched keys (a legacy
        // conflict lifting, say), so add new matches without dropping shown rows.
        .onChange(of: model.latestBindings) { refreshSearchIndexAfterBindingChange() }
        .onChange(of: model.legacyBindings) { refreshSearchIndexAfterBindingChange() }
        .onChange(of: model.managedBindingActionIDs) { refreshSearchIndexAfterBindingChange() }
        .onChange(of: model.whenOverrideRawStrings) { refreshSearchIndexAfterBindingChange() }
        .onChange(of: controlActiveState) { _, state in
            // A filter can shrink the list while inactive; drop the held
            // height once the window is active again.
            if state != .inactive {
                updateMeasuredHeight(to: lastReportedHeight)
            }
        }
        .task(id: SearchTaskID(query: query, revision: searchIndexRevision)) {
            if query.isEmpty {
                matchedActions = nil
                matchedActionsQuery = nil
                preserveShownOnIndexRefresh = false
                return
            }
            let index = searchIndex ?? model.shortcutSearchIndex()
            searchIndex = index
            let shown = preserveShownOnIndexRefresh ? shownActionsForIndexRefresh : nil
            do {
                try await Task.sleep(for: Self.searchDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                index.actions(matching: query, keeping: shown)
            }.value
            guard !Task.isCancelled else { return }
            matchedActions = results
            matchedActionsQuery = query
            preserveShownOnIndexRefresh = false
        }
    }

    /// Projects the observable model into the immutable values consumed by the
    /// lazy row tree. The projection stays above the `LazyVStack` boundary so
    /// individual rows never register observation dependencies on the model.
    private func rowEntries(for actions: [ShortcutAction]) -> [ShortcutListRowEntry] {
        actions.enumerated().map { index, action in
            let effective = model.effective(for: action)
            let snapshot = ShortcutListRowSnapshot(
                action: action,
                isLast: index == actions.count - 1,
                title: action.displayName,
                subtitle: model.scopeCaption(for: action),
                placeholder: model.formatPlaceholder(effective: effective, numbered: action.usesNumberedDigitMatching),
                chordsEnabled: model.chordModeActions.contains(action.rawValue),
                hasPendingRejection: model.hasPendingRejection(for: action),
                firstStrokeRequiresModifier: !action.allowsBareFirstStroke,
                isUnbound: effective?.isUnbound ?? true,
                canRestore: model.canRestore(for: action),
                validationMessage: model.validationMessage(for: action),
                recorderAccessibilityIdentifier: "ShortcutRecorder.\(action.rawValue)"
            )
            let rowActions = ShortcutListRowActions(
                onStroke: { stroke in Task { await model.assign(stroke: stroke, to: action) } },
                onChord: { chord in Task { await model.assignChord(chord, to: action) } },
                onBareKeyRejected: { model.markBareKeyRejected(action) },
                onClearOrRestore: { Task { await model.clearOrRestore(for: action) } },
                onClearRejections: { model.clearRejections(for: action) }
            )
            return ShortcutListRowEntry(snapshot: snapshot, actions: rowActions)
        }
    }

    /// Isolates the row tree from query state. A query change now updates this
    /// child only when matching produces a different action array, instead of
    /// diffing every visible row for each keystroke during the debounce.
    private struct ShortcutListRows: View, Equatable {
        let entries: [ShortcutListRowEntry]
        let revision: Int

        /// Compares only immutable row state so unchanged lazy rows stay mounted.
        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.entries.map(\.snapshot) == rhs.entries.map(\.snapshot)
                && lhs.revision == rhs.revision
        }

        /// Renders the stable empty state and shortcut rows.
        @MainActor
        var body: some View {
            LazyVStack(spacing: 0) {
                if entries.isEmpty {
                    Text(String(localized: "settings.shortcuts.search.noResults", defaultValue: "No shortcuts match"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .accessibilityIdentifier("SettingsShortcutSearchNoResults")
                }
                ForEach(entries, id: \.snapshot.action) { entry in
                    ShortcutListRowView(
                        snapshot: entry.snapshot,
                        actions: entry.actions
                    )
                    .equatable()
                }
            }
        }
    }

    private struct ShortcutListRowEntry {
        let snapshot: ShortcutListRowSnapshot
        let actions: ShortcutListRowActions
    }

    private func refreshSearchIndexAfterBindingChange() {
        searchIndex = model.shortcutSearchIndex()
        searchIndexRevision &+= 1
        guard !query.isEmpty else { return }
        guard matchedActionsQuery == query else {
            preserveShownOnIndexRefresh = false
            return
        }
        shownActionsForIndexRefresh = matchedActions ?? []
        preserveShownOnIndexRefresh = true
    }

    private struct SearchTaskID: Hashable {
        let query: ShortcutListSearchQuery
        let revision: Int
    }

    private func updateMeasuredHeight(to height: CGFloat) {
        guard height > 0 else { return }
        lastReportedHeight = height
        let nextHeight = controlActiveState == .inactive
            ? max(measuredHeight, height)
            : height
        if nextHeight != measuredHeight {
            measuredHeight = nextHeight
        }
    }
}
