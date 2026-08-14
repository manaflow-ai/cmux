import CmuxFoundation
import CmuxSettings

struct ShortcutListRowActions {
    let onStroke: (ShortcutStroke) -> Void
    let onChord: (StoredShortcut) -> Void
    let onToggleChordMode: () -> Void
    let onBareKeyRejected: () -> Void
    let onClearOrRestore: () -> Void
    let onClearRejections: () -> Void
}
