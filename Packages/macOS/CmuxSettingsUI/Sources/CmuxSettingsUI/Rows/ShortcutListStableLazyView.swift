import CmuxSettings
import SwiftUI

/// Lazy inline rendering of shortcut-recorder rows. It keeps the current active
/// list height as a minimum while inactive so app activation changes cannot
/// shrink the Settings document while off-screen rows are de-realized.
@MainActor
struct ShortcutListStableLazyView: View {
    @Environment(\.controlActiveState) private var controlActiveState

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
                    chordsEnabled: model.chordsEnabled(for: action),
                    canEditChord: action.allowsChordShortcut,
                    hasPendingRejection: model.hasPendingRejection(for: action),
                    // With a shared prefix the recorder seeds that leader and
                    // captures only the suffix.  The suffix may be bare even
                    // when this action's ordinary single stroke requires a
                    // modifier; without a shared prefix retain the legacy
                    // first-stroke validation.
                    firstStrokeRequiresModifier: model.prefix.isUnbound
                        && !action.allowsBareFirstStroke,
                    configuredPrefix: model.prefix.isUnbound ? nil : model.prefix.first,
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
                        onToggleChordMode: { model.toggleChordMode(for: action) },
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
    }

    private func updateMeasuredHeight(to height: CGFloat) {
        guard height > 0 else { return }
        let nextHeight = controlActiveState == .inactive
            ? max(measuredHeight, height)
            : height
        if nextHeight != measuredHeight {
            measuredHeight = nextHeight
        }
    }
}
