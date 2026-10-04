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
    @Environment(\.controlActiveState) private var controlActiveState

    let model: ShortcutListModel
    let query: ShortcutListSearchQuery
    @State private var measuredHeight: CGFloat = 0
    @State private var lastReportedHeight: CGFloat = 0
    /// Actions matching `query` when it last changed, or `nil` when unfiltered.
    @State private var matchedActions: [ShortcutAction]?

    var body: some View {
        let actions = matchedActions ?? ShortcutAction.settingsVisibleActions
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
        .background {
            ShortcutListHeightReader { height in
                updateMeasuredHeight(to: height)
            }
        }
        .frame(minHeight: measuredHeight, alignment: .top)
        .onChange(of: query, initial: true) { _, query in
            matchedActions = query.isEmpty ? nil : model.actions(matching: query)
        }
        // A binding edit can give another action the searched keys (a legacy
        // conflict lifting, say), so add new matches without dropping shown rows.
        .onChange(of: model.latestBindings) { refreshMatchesAfterBindingChange() }
        .onChange(of: model.legacyBindings) { refreshMatchesAfterBindingChange() }
        .onChange(of: model.managedBindingActionIDs) { refreshMatchesAfterBindingChange() }
        .onChange(of: model.whenOverrideRawStrings) { refreshMatchesAfterBindingChange() }
        .onChange(of: controlActiveState) { _, state in
            // A filter can shrink the list while inactive; drop the held
            // height once the window is active again.
            if state != .inactive {
                updateMeasuredHeight(to: lastReportedHeight)
            }
        }
    }

    private func refreshMatchesAfterBindingChange() {
        guard let shown = matchedActions else { return }
        matchedActions = model.actions(matching: query, keeping: shown)
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
