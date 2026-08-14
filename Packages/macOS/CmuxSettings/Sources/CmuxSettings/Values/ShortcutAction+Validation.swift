extension ShortcutAction {
    /// Whether this action rejects `shortcut` because it contains a system-defined media key.
    ///
    /// Global Search is handled by the foreground AppKit key path, which cannot
    /// receive media-key events. Other actions retain their existing validation.
    ///
    /// - Parameter shortcut: The shortcut being validated.
    /// - Returns: `true` when the shortcut cannot execute for this action.
    public func rejectsSystemDefinedMediaKey(_ shortcut: StoredShortcut) -> Bool {
        rejectsSystemDefinedMediaKey(
            firstKey: shortcut.first.key,
            secondKey: shortcut.second?.key
        )
    }

    /// Whether this action rejects shortcut keys from a legacy binding representation.
    ///
    /// - Parameters:
    ///   - firstKey: The persisted key identifier for the first stroke.
    ///   - secondKey: The persisted key identifier for the optional chord suffix.
    /// - Returns: `true` when either key is a media key this action cannot execute.
    public func rejectsSystemDefinedMediaKey(
        firstKey: String,
        secondKey: String?
    ) -> Bool {
        guard self == .globalSearch else { return false }
        return firstKey.lowercased().hasPrefix("media.")
            || secondKey?.lowercased().hasPrefix("media.") == true
    }

    /// Whether the system reserves this complete shortcut before the action can execute it.
    ///
    /// Escape is reserved as the cancellation gesture for a pending prefix
    /// chord. Command-Period is AppKit's standard cancel keystroke for modal
    /// alerts and open/save panels; the system-wide Show/Hide action must not
    /// capture that first instinctive cancel press.
    ///
    /// - Parameter shortcut: The shortcut being validated.
    /// - Returns: `true` when the shortcut is reserved for system interaction.
    public func rejectsSystemReservedShortcut(
        _ shortcut: StoredShortcut
    ) -> Bool {
        if shortcut.hasChord {
            let second = shortcut.second?.canonicalized()
            return second?.key.lowercased() == "escape"
                || second?.key == "\u{1b}"
        }
        guard self == .showHideAllWindows else { return false }
        let first = shortcut.first.canonicalized()
        return first.key == "."
            && first.command
            && !first.shift
            && !first.option
            && !first.control
    }
}
