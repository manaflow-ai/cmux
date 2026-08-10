/// Describes how refreshed global-search results update the current selection.
enum GlobalSearchPopoverSelectionUpdate: Equatable {
    case reset
    case preserveCurrentHit
}
