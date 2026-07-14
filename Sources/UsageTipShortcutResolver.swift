@MainActor
struct UsageTipShortcutResolver {
    private let lookup: (KeyboardShortcutSettings.Action) -> StoredShortcut?

    init(
        lookup: @escaping (KeyboardShortcutSettings.Action) -> StoredShortcut? = {
            KeyboardShortcutSettings.shortcutIfBound(for: $0)
        }
    ) {
        self.lookup = lookup
    }

    func displayString(for action: KeyboardShortcutSettings.Action) -> String? {
        guard let shortcut = lookup(action), !shortcut.isUnbound else { return nil }
        return action.displayedShortcutString(for: shortcut)
    }
}
