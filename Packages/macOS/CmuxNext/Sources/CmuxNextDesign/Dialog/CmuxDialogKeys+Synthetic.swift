// Keys an automation socket names (`debug.dialog {key}`, `debug.key`), and the dialogs its synthetic input never answers.
extension CmuxDialogKeys {
    /// A key by `debug.dialog`'s name: `return`, `escape`, `tab`, `shift-tab`, `cmd-<c>`.
    public static func named(_ name: String) -> (Key, Modifiers)? {
        switch name {
        case "return": return (.return, [])
        case "escape": return (.escape, [])
        case "tab": return (.tab, [])
        case "shift-tab": return (.tab, .shift)
        default:
            guard name.hasPrefix("cmd-"), name.count == 5, let character = name.last else { return nil }
            return (.character(character), .command)
        }
    }

    /// Synthetic input (`debug.key`, `debug.view_key`, `debug.mouse`) while a dialog in `userOnly` shows: refused, since a
    /// Return reaches the blocking dialog's keyboard (`KeyRouter.answersBlockingDialog`) and a click lands on its buttons,
    /// so an agent would answer it as the person (review follow-up on #43392, F1). Input that `onlyCancels` (a bare
    /// Escape, a read) stays, as `debug.dialog {dismiss}` does. The refusal's message, or nil when the input may run.
    public static func syntheticInputRefusal(_ records: [CmuxDialogCenter.Record], userOnly: Set<String>, onlyCancels: Bool) -> String? {
        guard !onlyCancels, records.contains(where: { $0.visible && $0.spec.identifier.map(userOnly.contains) == true }) else { return nil }
        return "a dialog that answers only to the user is open: synthetic input may only cancel it (Escape)"
    }

    /// A `debug.key` request that only cancels or reads: a bare Escape with no `modifiers` and no `sequence`, or `read`
    /// (`last`, `dry_run`).
    public static func onlyCancels(key: String?, modifiers: Int, sequence: Bool, read: Bool) -> Bool {
        read || (!sequence && key == "escape" && modifiers == 0)
    }
}
