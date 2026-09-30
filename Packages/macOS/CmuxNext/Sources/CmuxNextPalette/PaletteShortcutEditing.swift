public import CmuxNextActions

// The recorder lives in CmuxNextActions (`ShortcutRecorder`) so the palette
// and the Settings window share one recorder and one conflict policy. These
// names keep the palette's public API.
public typealias PaletteShortcutEditing = ShortcutRecorderEditing
public typealias PaletteShortcutOption = ShortcutRecorderOption
public typealias PaletteShortcutPending = ShortcutRecorderPending
public typealias PaletteShortcutRecorderState = ShortcutRecorderState
