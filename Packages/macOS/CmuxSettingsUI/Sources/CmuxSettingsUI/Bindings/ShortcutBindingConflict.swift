import CmuxSettings

/// A complete runtime-overlap query for two stored shortcut bindings.
struct ShortcutBindingConflict {
    let proposed: StoredShortcut
    let proposedUsesNumberedDigitMatching: Bool
    let configured: StoredShortcut
    let configuredUsesNumberedDigitMatching: Bool

    /// Whether the bindings can consume the same keystroke sequence.
    var exists: Bool {
        guard !proposed.isUnbound, !configured.isUnbound else { return false }

        switch (proposed.second, configured.second) {
        case (nil, nil):
            return numberedAwareStrokesConflict(
                proposed.first,
                numbered: proposedUsesNumberedDigitMatching,
                configured.first,
                numbered: configuredUsesNumberedDigitMatching
            )
        case let (proposedSecond?, configuredSecond?):
            return numberedAwareStrokesConflict(
                proposed.first,
                numbered: false,
                configured.first,
                numbered: false
            ) && numberedAwareStrokesConflict(
                proposedSecond,
                numbered: proposedUsesNumberedDigitMatching,
                configuredSecond,
                numbered: configuredUsesNumberedDigitMatching
            )
        case (_?, nil):
            return numberedAwareStrokesConflict(
                proposed.first,
                numbered: false,
                configured.first,
                numbered: configuredUsesNumberedDigitMatching
            )
        case (nil, _?):
            return numberedAwareStrokesConflict(
                proposed.first,
                numbered: proposedUsesNumberedDigitMatching,
                configured.first,
                numbered: false
            )
        }
    }
}
