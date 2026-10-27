public import CmuxNextActionsAppKit

// The recorder lives in CmuxNextActions (`ShortcutRecorder`) so the palette
// and the Settings window share one recorder and one conflict policy. These
// names keep the palette's public API.
public typealias PaletteShortcutEditing = ShortcutRecorderEditing
public typealias PaletteShortcutOption = ShortcutRecorderOption
public typealias PaletteShortcutRecorderState = ShortcutRecorderState
