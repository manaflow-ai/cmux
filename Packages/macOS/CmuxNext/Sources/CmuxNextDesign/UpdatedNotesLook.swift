public import CmuxNextDesignTokens

/// How the "cmux Updated!" card's changes stand in their popover beside the sidebar (Debug Settings
/// `sidebar.updatedCard.notesLook`; the page is UpdatedNotes.tsx).
///
/// Lawrence 2026-11-09, on the popover ("Updated to Nightly", the Agent Chat list, "+162 more"):
/// "make and show me more versions of this ui". ``sections`` ships until one is picked; the others
/// each answer the list's question on another axis. The page reads the look live, from the theme's
/// `updated-notes-look` slot (``ThemeDecorations``).
public nonisolated enum UpdatedNotesLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The changes under their areas' headers, one pill each, "+N more" while more are below (ships).
    case sections
    /// One line per area with its count and first titles; a click opens the area in place.
    case digest
    /// The areas as filter chips over one list of the changes.
    case chips
    /// The first three changes at full size with their whole details, then See all changes.
    case headline
    /// One line per change, its area as a quiet label beside the first of each area.
    case ledger

    /// The look that ships.
    public static let shipped: UpdatedNotesLook = .sections

    public var tunableTitle: String {
        switch self {
        case .sections: "Sections (current)"
        case .digest: "Digest: one line per area"
        case .chips: "Chips: filter by area"
        case .headline: "Headline: top three, then See all"
        case .ledger: "Ledger: one line per change"
        }
    }

    public static let tunable = Tunable<UpdatedNotesLook>.choice(
        "sidebar.updatedCard.notesLook", .sidebar, "Updated card changes list",
        help: "How the \"cmux Updated!\" card's changes stand in the popover beside the sidebar: under area headers (current), one line per area, filtered by area chips, the top three at full size, or one line per change. Applies at once.",
        default: .shipped, code: "UpdatedNotesLook.tunable")
}
