import CmuxSettings
import SwiftUI

/// Full-height inline rendering of the shortcut-recorder rows: a plain eager
/// `VStack` that flows directly in the Settings page scroll with no inner scroll
/// region, so the whole list is part of the one continuous page (matching the
/// upstream layout).
///
/// Deliberately NOT a `LazyVStack`. The `LazyVStack` is the original scroll-jump
/// bug: on the app active-state flip it de-realizes off-screen rows and
/// re-estimates them shorter, dipping the page's document height so `NSClipView`
/// re-anchors the scroll and strands it. An eager `VStack` keeps every row
/// realized, so the page height is stable across the flip and the jump cannot
/// occur. The cost is realizing all rows (~166 Carbon-backed recorders) up front
/// at window-open.
///
/// Uses ``ShortcutListModel`` (all state/logic) and ``ShortcutListRowView`` (all
/// rendering, including its own `isLast` hairline divider).
@MainActor
struct ShortcutListEagerView: View {
    let model: ShortcutListModel

    var body: some View {
        let actions = ShortcutAction.settingsVisibleActions
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                let effective = model.effective(for: action)
                let snapshot = ShortcutListRowSnapshot(
                    action: action,
                    isLast: index == actions.count - 1,
                    title: action.displayName,
                    subtitle: model.scopeCaption(for: action),
                    placeholder: model.formatPlaceholder(effective: effective, numbered: action.usesNumberedDigitMatching),
                    chordsEnabled: model.chordModeActions.contains(action.rawValue),
                    hasPendingRejection: model.bareKeyRejections.contains(action.rawValue)
                        || model.numberedDigitRejections.contains(action.rawValue),
                    firstStrokeRequiresModifier: !action.allowsBareFirstStroke,
                    isUnbound: effective?.isUnbound ?? true,
                    canRestore: model.canRestore(for: action),
                    validationMessage: model.validationMessage(for: action)
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
