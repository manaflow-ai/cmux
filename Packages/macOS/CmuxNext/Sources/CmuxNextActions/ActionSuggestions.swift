import Foundation

/// Known values of a free-text argument. The App supplies the full list for
/// `source` (`ActionRegistry.argumentSuggestions`, `PaletteSources`); the
/// palette offers it with type-to-search and still accepts other text; a
/// context menu offers `pinned` plus an item that opens the full list.
public nonisolated struct ActionSuggestions: Sendable, Hashable {
    /// Which list the App supplies (`ghosttyThemes`).
    public let source: String
    /// Shown first in pickers and as the context menu's items.
    public let pinned: [ActionEnumCase]
    /// Title of the palette row that takes other text (a light/dark pair).
    public let otherTitle: String?
    /// The argument takes several values, comma-joined (a group's members): the palette keeps
    /// its list open, each chosen value a chip in the search field, until Continue.
    public let allowsMultiple: Bool

    public init(source: String, pinned: [ActionEnumCase], otherTitle: String? = nil, allowsMultiple: Bool = false) {
        self.source = source
        self.pinned = pinned
        self.otherTitle = otherTitle
        self.allowsMultiple = allowsMultiple
    }

    /// Every Ghostty theme (the App lists them).
    public static let ghosttyThemes = "ghosttyThemes"
    /// Items `sidebar.item.add` puts in the sidebar: the built-ins, plus
    /// `workspace:<id>` and `app:<publisher>/<name>` typed as text.
    public static let sidebarItems = "sidebarItems"
    /// Every density: the built-ins, then the user's custom ones (the App lists them).
    public static let densities = "densities"
    /// The Home conversations a message can go to (Send Message To…, Send To…; Chiefs first).
    public static let homeRecipients = "homeRecipients"
    /// The people and Chiefs a new group can have (New Group Chat's `members`), by participant id:
    /// the user's Chiefs (main first), the team, then the people of their DMs.
    public static let homeMembers = "homeMembers"
    /// The names of this Mac's layout templates (New Workspace from Template's `template`).
    public static let layoutTemplates = "layoutTemplates"
    /// Backgrounds a pane may take (`pane.setBackground`): the bundled art, by title.
    public static let paneBackgrounds = "paneBackgrounds"
    /// Marker tints a pane may take (`pane.setTint`): the pinned named colors.
    public static let paneTints = "paneTints"
    /// The cmux Cloud teams of the signed-in account (Team Picker's `team`), by team id.
    public static let cloudTeams = "cloudTeams"
    /// The machines a Chief can move to (Move Chief To…'s `target`), by machine id; a target that
    /// cannot take the Chief yet says why in its title.
    public static let chiefMoveTargets = "chiefMoveTargets"
    /// The archived workspaces Restore Archived Workspace… offers (by document item), last used first.
    public static let archivedWorkspaces = "archivedWorkspaces"
    /// Every notification sound installed (`~/Library/Sounds`, `/Library/Sounds`, the system's), by name.
    public static let notificationSounds = "notificationSounds"
    /// The agent kinds this Mac has seen (its agent chats' harnesses), for per-agent notification sounds.
    public static let notificationAgents = "notificationAgents"
    /// The hosts New Remote Group offers (its `destination`): connected machines, online Tailscale
    /// peers, then `~/.ssh/config` aliases, each once, by SSH destination.
    public static let remoteHosts = "remoteHosts"
}
