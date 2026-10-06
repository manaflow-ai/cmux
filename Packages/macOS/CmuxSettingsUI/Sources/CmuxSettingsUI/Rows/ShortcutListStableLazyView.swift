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
    private static let searchDebounce: Duration = .milliseconds(180)

    @Environment(\.controlActiveState) private var controlActiveState

    let model: ShortcutListModel
    let query: ShortcutListSearchQuery
    @State private var measuredHeight: CGFloat = 0
    @State private var lastReportedHeight: CGFloat = 0
    /// Actions matching `query` when it last changed, or `nil` when unfiltered.
    @State private var matchedActions: [ShortcutAction]?
    @State private var searchIndex: ShortcutListSearchIndex?
    @State private var searchIndexRevision = 0
    @State private var preserveShownOnIndexRefresh = false
    @State private var shownActionsForIndexRefresh: [ShortcutAction] = []

    var body: some View {
        let actions = matchedActions ?? ShortcutAction.settingsVisibleActions
        ShortcutListRows(model: model, actions: actions, revision: searchIndexRevision)
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
        .task(id: SearchTaskID(query: query, revision: searchIndexRevision, preserveShown: preserveShownOnIndexRefresh)) {
            if query.isEmpty {
                matchedActions = nil
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
            preserveShownOnIndexRefresh = false
        }
    }

    /// Isolates the row tree from query state. A query change now updates this
    /// child only when matching produces a different action array, instead of
    /// diffing every visible row for each keystroke during the debounce.
    private struct ShortcutListRows: View, Equatable {
        let model: ShortcutListModel
        let actions: [ShortcutAction]
        let revision: Int

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.actions == rhs.actions && lhs.revision == rhs.revision
        }

        @MainActor
        var body: some View {
            LazyVStack(spacing: 0) {
                if actions.isEmpty {
                    Text(String(localized: "settings.shortcuts.search.noResults", defaultValue: "No shortcuts match"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .accessibilityIdentifier("SettingsShortcutSearchNoResults")
                }
                ForEach(Array(actions.enumerated()), id: \.element) { index, action in
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
                    ShortcutListRowView(
                        snapshot: snapshot,
                        actions: ShortcutListRowActions(
                            onStroke: { stroke in Task { await model.assign(stroke: stroke, to: action) } },
                            onChord: { chord in Task { await model.assignChord(chord, to: action) } },
                            onBareKeyRejected: { model.markBareKeyRejected(action) },
                            onClearOrRestore: { Task { await model.clearOrRestore(for: action) } },
                            onClearRejections: { model.clearRejections(for: action) }
                        )
                    )
                    .equatable()
                }
            }
        }
    }

    private func refreshSearchIndexAfterBindingChange() {
        searchIndex = model.shortcutSearchIndex()
        searchIndexRevision &+= 1
        guard !query.isEmpty else { return }
        shownActionsForIndexRefresh = matchedActions ?? []
        preserveShownOnIndexRefresh = true
    }

    private struct SearchTaskID: Hashable {
        let query: ShortcutListSearchQuery
        let revision: Int
        let preserveShown: Bool
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
