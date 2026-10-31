public import CmuxHomeCore

/// One row of New Message's list under To: (``HomeRecipientSuggestionsView``): a section header,
/// a recipient, or an action row (New Chief, Invite) that runs instead of adding a token.
public enum HomeRecipientSuggestion: Hashable, Sendable {
    /// A section's title ("Chiefs", "Team"); never highlighted or picked.
    case header(String)
    /// Someone to add as a token.
    case recipient(HomeRecipient)
    /// Makes another Chief (`home.newChief`), after the Chiefs.
    case newChief
    /// Invites someone to the team (`home.invite`), when the Team section has nobody.
    case invite
    /// Invites the typed address to the active team (`home.inviteToTeam`, its confirmation dialog),
    /// after the address row.
    case inviteToTeam(ContactAddress, team: String)

    /// False for a header: Up, Down, a click and Return skip it.
    public var isSelectable: Bool {
        if case .header = self { return false }
        return true
    }
}
