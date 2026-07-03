import CmuxSettings
import SwiftUI

private struct ShortcutListHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Lazy inline rendering of shortcut-recorder rows. It records the largest
/// measured list height and keeps that as a minimum so app activation changes
/// cannot shrink the Settings document while off-screen rows are de-realized.
@MainActor
struct ShortcutListStableLazyView: View {
    let model: ShortcutListModel
    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        let actions = ShortcutAction.settingsVisibleActions
        LazyVStack(spacing: 0) {
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
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ShortcutListHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
        .frame(minHeight: measuredHeight, alignment: .top)
        .onPreferenceChange(ShortcutListHeightPreferenceKey.self) { height in
            if height > measuredHeight {
                measuredHeight = height
            }
        }
    }
}
