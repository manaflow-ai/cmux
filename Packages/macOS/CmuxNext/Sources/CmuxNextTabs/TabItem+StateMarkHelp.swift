import CmuxNextDesign

extension TabItem {
    /// The tooltip of the mark at the tab's trailing end (`TabCell.badgeColor`, or a status icon
    /// set's glyph): what the dot means, so a person never has to guess a color. Nil when the tab
    /// draws no mark.
    var stateMarkHelp: String? {
        switch status {
        case .needsInput:
            guard let kind = blockedKind, let label = StatusIndicatorState.waiting(kind: kind).shortLabel else {
                return Strings.stateMarkNeedsInput
            }
            return Strings.stateMarkNeedsInputKind(label)
        case .success: return Strings.stateMarkSuccess
        case .failure: return Strings.stateMarkFailure
        case .none: return isUnread ? Strings.stateMarkUnread : nil
        }
    }
}
