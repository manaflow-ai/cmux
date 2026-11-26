public import CmuxNextActions
public import CmuxNextHomeModel

extension HomeMessageRouting {
    /// The palette's known values of a Home argument: ``ActionSuggestions/homeRecipients`` (the
    /// conversations a message can go to), ``ActionSuggestions/homeMembers`` (who a new group can
    /// have, by participant id) or ``ActionSuggestions/homeChiefs`` (which Chief); nil for any other source.
    /// - Parameters:
    ///   - source: The argument's suggestion source.
    ///   - members: Who a group can have (``HomeChiefRoster/groupMembers(_:rows:excluding:)``), read
    ///     only for ``ActionSuggestions/homeMembers``.
    ///   - chiefs: The user's Chiefs (``HomeDirectory/chiefSuggestions()``), read only for
    ///     ``ActionSuggestions/homeChiefs``.
    /// - Returns: The values, or nil when `source` is not a Home one.
    public func suggestions(for source: String, members: @autoclosure () -> [HomeContact],
                            chiefs: @autoclosure () -> [ActionEnumCase] = []) -> [ActionEnumCase]? {
        let members = source == ActionSuggestions.homeMembers ? members() : []
        let reply: Suggestions? = HomeComposeRules().call(
            "routing.suggestions", routing(source: source, members: members), fallback: nil)
        guard let reply, let kind = reply.source else { return nil }
        if kind == "chiefs" { return chiefs() }
        return (reply.choices ?? []).map { ActionEnumCase(value: $0.value, title: $0.title) }
    }

    /// `compose.routing.suggestions`' reply: which list `source` names, and its values.
    private struct Suggestions: Decodable {
        var source: String?
        var choices: [HomeComposeRules.Choice]?
    }
}
