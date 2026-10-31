public import CmuxNextActions
public import CmuxNextHome

extension HomeMessageRouting {
    /// The palette's known values of a Home argument: ``ActionSuggestions/homeRecipients`` (the
    /// conversations a message can go to) or ``ActionSuggestions/homeMembers`` (who a new group can
    /// have, by participant id); nil for any other source.
    /// - Parameters:
    ///   - source: The argument's suggestion source.
    ///   - members: Who a group can have (``HomeChiefRoster/groupMembers(_:rows:excluding:)``), read
    ///     only for ``ActionSuggestions/homeMembers``.
    /// - Returns: The values, or nil when `source` is not a Home one.
    public func suggestions(for source: String, members: @autoclosure () -> [HomeContact]) -> [ActionEnumCase]? {
        switch source {
        case ActionSuggestions.homeRecipients: recipients().map { ActionEnumCase(value: $0.value, title: $0.title) }
        case ActionSuggestions.homeMembers: members().map { ActionEnumCase(value: $0.id.rawValue, title: $0.name) }
        default: nil
        }
    }
}
