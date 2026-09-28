/// The hover text and the assistive-technology label for one Cloud row.
///
/// Both belong to the cell rather than to the hosted SwiftUI content.
/// `CloudTreePassthroughHostingView` returns nil from `hitTest` so the outline
/// owns every pointer event, which also means a `.help()` inside a row view
/// never receives the hover that would show it. Rows that kept their secondary
/// information "on hover" had no way to present it to a pointer; computing it
/// here and letting `CloudTreeCellView` assign `toolTip` gives every row kind
/// one tooltip path and one accessibility path.
struct CloudTreeRowDescription: Equatable {
    /// nil leaves the cell without hover text: short, fixed group labels.
    let toolTip: String?
    let accessibilityLabel: String
}
