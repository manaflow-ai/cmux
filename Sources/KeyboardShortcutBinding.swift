import CmuxSettings

struct KeyboardShortcutBinding: Equatable {
    let action: KeyboardShortcutSettings.Action
    let shortcut: StoredShortcut
    let whenClause: ShortcutWhenClause
}
