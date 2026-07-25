import CmuxSettings

extension Dictionary where Key == String, Value == StoredShortcut {
    /// Removes bindings that the owning action cannot execute.
    func removingBindingsRejectedByActionPolicy() -> Self {
        filter { rawAction, shortcut in
            guard let action = ShortcutAction(rawValue: rawAction) else { return true }
            return !action.rejectsSystemDefinedMediaKey(shortcut)
        }
    }
}
