import CmuxSettings

/// A complete runtime-overlap query for two stored shortcut bindings.
struct ShortcutBindingConflict {
    let proposed: StoredShortcut
    let proposedNumberedDigitRange: ClosedRange<Int>?
    let configured: StoredShortcut
    let configuredNumberedDigitRange: ClosedRange<Int>?

    /// Whether the bindings can consume the same keystroke sequence.
    var exists: Bool {
        guard !proposed.isUnbound, !configured.isUnbound else { return false }

        switch (proposed.second, configured.second) {
        case (nil, nil):
            return numberedAwareStrokesConflict(
                proposed.first,
                numberedRange: proposedNumberedDigitRange,
                configured.first,
                numberedRange: configuredNumberedDigitRange
            )
        case let (proposedSecond?, configuredSecond?):
            return numberedAwareStrokesConflict(
                proposed.first,
                numberedRange: nil,
                configured.first,
                numberedRange: nil
            ) && numberedAwareStrokesConflict(
                proposedSecond,
                numberedRange: proposedNumberedDigitRange,
                configuredSecond,
                numberedRange: configuredNumberedDigitRange
            )
        case (_?, nil):
            return numberedAwareStrokesConflict(
                proposed.first,
                numberedRange: nil,
                configured.first,
                numberedRange: configuredNumberedDigitRange
            )
        case (nil, _?):
            return numberedAwareStrokesConflict(
                proposed.first,
                numberedRange: proposedNumberedDigitRange,
                configured.first,
                numberedRange: nil
            )
        }
    }
}
