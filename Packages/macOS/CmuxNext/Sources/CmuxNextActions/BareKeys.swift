/// Bare keys (no Command, Control or Option: `j`, `G`, `/`, `g g`, `] f`) in pages that own
/// them (R59 with hq-48, K1 of plans/cmux-next/customization.md): everywhere else a bare key is
/// typing. One rule set for every client and the daemon's keybindings.json reader
/// (cmux-config `keybindings::bare`), pinned by `schemas/keybindings/keybinding-vectors.json`:
///
/// - an entry whose first key is bare binds only when its `when` requires a bare-key context
///   (one of ``ownerKeys`` as an `&&` term) and requires none that can hold while a text field
///   has the keyboard (``textKeys``); a `||` at the top proves nothing, so it is refused;
/// - such a sequence arms only while the context owns bare keys (``KeyContext/ownsBareKeys``).
public nonisolated enum BareKeys {
    /// The context keys of ``ActionContext/bareKeyOwners``.
    public static let ownerKeys: Set<String> = Set(ActionContext.keyNames.filter { ActionContext.bareKeyOwners.contains($0.0) }.map(\.1))

    /// Context keys that can hold while a text field (native or in a page) has the keyboard.
    public static let textKeys: Set<String> = [
        KeyContext.textInputFocus, "textBoxFocused", "omnibarFocused", "terminalFocused", "agentPaneFocused",
        "codeEditorFocused", "markdownEditorFocused", "browserFocused",
    ]

    /// No Command, Control or Option (Shift is part of the key: G, ?).
    public static func isBare(_ key: Shortcut) -> Bool {
        key.modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// Whether an entry whose first key is bare may bind under `when`.
    public static func mayBind(when: WhenClause?) -> Bool {
        let required = Set((when?.conjuncts ?? []).compactMap { term -> String? in
            if case .has(let key) = term { return key }
            return nil
        })
        return !required.isDisjoint(with: ownerKeys) && required.isDisjoint(with: textKeys)
    }
}

extension KeyContext {
    /// The focused page owns bare keys now: a bare-key context holds and no text field (native or
    /// in the page) has the keyboard.
    public nonisolated var ownsBareKeys: Bool {
        !bits.isDisjoint(with: ActionContext.bareKeyOwners) && self[KeyContext.textInputFocus] != .bool(true)
    }
}
