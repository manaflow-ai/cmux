struct ShortcutRecorderRejectedAttempt: Equatable {
    let reason: KeyboardShortcutSettings.ShortcutRecordingRejection
    let proposedShortcut: StoredShortcut?
}
