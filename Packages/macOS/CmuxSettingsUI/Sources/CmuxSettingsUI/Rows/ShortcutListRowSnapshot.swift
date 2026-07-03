import CmuxFoundation
import CmuxSettings

struct ShortcutListRowSnapshot: Equatable {
    let action: ShortcutAction
    let isLast: Bool
    let title: String
    let subtitle: String?
    let placeholder: String
    let chordsEnabled: Bool
    let hasPendingRejection: Bool
    let firstStrokeRequiresModifier: Bool
    let isUnbound: Bool
    let canRestore: Bool
    let validationMessage: String?
}

struct ShortcutListRowActions {
    let onStroke: (ShortcutStroke) -> Void
    let onChord: (StoredShortcut) -> Void
    let onBareKeyRejected: () -> Void
    let onClearOrRestore: () -> Void
    let onClearRejections: () -> Void
}
