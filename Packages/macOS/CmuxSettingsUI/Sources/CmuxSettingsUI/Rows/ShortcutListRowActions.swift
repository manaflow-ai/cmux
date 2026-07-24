import CmuxFoundation
import CmuxSettings

struct ShortcutListRowActions {
    let onStroke: (ShortcutStroke) -> Void
    let onChord: (StoredShortcut) -> Void
    let onBareKeyRejected: () -> Void
    let onToggleChordMode: () -> Void
    let onClearOrRestore: () -> Void
    let onClearRejections: () -> Void
}
