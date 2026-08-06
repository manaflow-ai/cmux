import Foundation

/// Which marker folder defines the top of the note collection when the markdown
/// viewer resolves `[[Wiki]]` links.
///
/// Wiki-link resolution walks up from the open file to the nearest ancestor
/// directory that contains the chosen marker folder, then resolves the note by
/// name anywhere under it. Making the marker explicit turns "look around the
/// filesystem" into "you picked the anchor folder for your notes."
public enum MarkdownWikiLinkAnchor: String, CaseIterable, Sendable, SettingCodable {
    /// Anchor at the nearest Obsidian vault (a folder containing `.obsidian`).
    case obsidian
    /// Anchor at the nearest Git repository (a folder containing `.git`).
    case git

    /// The marker entry looked for in ancestor directories.
    public var markerName: String {
        switch self {
        case .obsidian: return ".obsidian"
        case .git: return ".git"
        }
    }
}
