// Bare keys (no Command, Control or Option: `j`, `G`, `/`, `g g`, `] f`) in pages that own
// them (R59 with hq-48, K1 of plans/cmux-next/customization.md): everywhere else a bare key is
// typing. One rule set for every client and the daemon's keybindings.json reader
// (cmux-config `keybindings::bare`), pinned by `schemas/keybindings/keybinding-vectors.json`:
//
// - an entry whose first key is bare binds only when its `when` requires a bare-key context
//   (one of ``ActionContext/bareKeyOwnerKeys`` as an `&&` term) and requires none that can hold
//   while a text field has the keyboard (``KeyContext/textFieldKeys``); a `||` at the top proves
//   nothing, so it is refused (``WhenClause/allowsBareKeys``);
// - such a sequence arms only while the context owns bare keys (``KeyContext/ownsBareKeys``).

extension ActionContext {
    /// The context keys of ``bareKeyOwners``.
    public nonisolated static let bareKeyOwnerKeys: Set<String> = Set(keyNames.filter { bareKeyOwners.contains($0.0) }.map(\.1))
}

extension KeyContext {
    /// Context keys that can hold while a text field (native or in a page) has the keyboard.
    public nonisolated static let textFieldKeys: Set<String> = [
        textInputFocus, "textBoxFocused", "omnibarFocused", "terminalFocused", "agentPaneFocused",
        "codeEditorFocused", "markdownEditorFocused", "browserFocused",
    ]

    /// The focused page owns bare keys now: a bare-key context holds and no text field (native or
    /// in the page) has the keyboard.
    public nonisolated var ownsBareKeys: Bool {
        !bits.isDisjoint(with: ActionContext.bareKeyOwners) && self[KeyContext.textInputFocus] != .bool(true)
    }
}

extension Shortcut {
    /// No Command, Control or Option (Shift is part of the key: G, ?).
    public nonisolated var isBare: Bool {
        modifiers.isDisjoint(with: [.command, .control, .option])
    }
}

extension WhenClause {
    /// Whether an entry whose first key is bare may bind under this clause: it requires a bare-key
    /// owner as an `&&` term and no key that holds while a text field has the keyboard.
    public nonisolated var allowsBareKeys: Bool {
        let required = Set(conjuncts.compactMap { term -> String? in
            if case .has(let key) = term { return key }
            return nil
        })
        return !required.isDisjoint(with: ActionContext.bareKeyOwnerKeys) && required.isDisjoint(with: KeyContext.textFieldKeys)
    }
}
