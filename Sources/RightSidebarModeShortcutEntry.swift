/// Binds one right-sidebar mode to its optional action and cached shortcut.
struct RightSidebarModeShortcutEntry {
    let mode: RightSidebarMode
    let action: KeyboardShortcutSettings.Action?
    let shortcut: StoredShortcut
}
