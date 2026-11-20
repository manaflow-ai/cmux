public import CmuxNextDesignTokens

/// Where the "cmux Updated!" card shows the update's changes (Debug Settings
/// `sidebar.updatedCard.preview`).
///
/// Lawrence 2026-11-07, on the list that grew up out of the bottom card over the sidebar: "i dont
/// like how it expands upwards, also it looks very bad". The shipped look keeps the card still and
/// opens the changes beside the sidebar, in the app's one hover card window, as the staged update
/// card's popover does. The other looks are kept to compare.
public nonisolated enum UpdatedCardPreviewMode: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// Resting on the card opens its changes beside the sidebar, in the hover card window: the
    /// header (the full version, What's New), then each change's title and detail.
    case beside
    /// The same popover with each change's title alone.
    case besideTitles = "beside-titles"
    /// The card's second line is the full version; resting on it opens the changes beside it.
    case version
    /// No change list: the card's second line is "See What's New ↗", and the card opens the page.
    case quiet
    /// The list grows up out of the card over the sidebar's rows (the look before).
    case above

    /// The look that ships.
    public static let shipped: UpdatedCardPreviewMode = .beside

    /// Whether the changes open in the hover card window beside the sidebar.
    public var opensBeside: Bool {
        switch self {
        case .beside, .besideTitles, .version: true
        case .quiet, .above: false
        }
    }

    public var tunableTitle: String {
        switch self {
        case .beside: "Beside the sidebar (popover)"
        case .besideTitles: "Beside the sidebar, titles only"
        case .version: "Full version on the card, popover beside"
        case .quiet: "No list: See What's New"
        case .above: "List grows up over the sidebar (before)"
        }
    }

    public static let tunable = Tunable<UpdatedCardPreviewMode>.choice(
        "sidebar.updatedCard.preview", .sidebar, "Updated card changes",
        help: "Where the \"cmux Updated!\" card shows the update's changes: in a popover beside the sidebar, with or without details, with the full version on the card, not at all, or in a list that grows up over the sidebar (the look before). Applies to the next card that shows.",
        default: .shipped, code: "UpdatedCardPreviewMode.tunable")
}
