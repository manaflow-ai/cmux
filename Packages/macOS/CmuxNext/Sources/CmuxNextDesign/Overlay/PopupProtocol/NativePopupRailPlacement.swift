import Foundation

/// NativePopupRailPlacement on the native popup wire: where the rail's tabs sit, as the web
/// picker's harness placements draw them. Absent: the original column beside the title and search.
public enum NativePopupRailPlacement: String, Codable, Equatable, Sendable {
    /// A wrapping row of marks across the top; a name is only the tab's tooltip and accessible name.
    case `symbols`
    /// A column of marks with their names.
    case `left`
    /// A wrapping strip of marks with their names across the top.
    case `top`
    /// A narrow column, each name under its mark.
    case `compact`
}
