public import Foundation

/// The short word shown in the filter field's scope chip.
public struct SidebarFilterScopeLabel: Sendable {
    /// Returns the chip label for `field`.
    ///
    /// - Parameter field: The field a sigil scoped the query to.
    /// - Returns: A lowercase, localized noun short enough for the chip.
    public static func text(for field: SidebarFilterField) -> String {
        switch field {
        case .title:
            return String(localized: "sidebar.filter.scope.title", defaultValue: "title")
        case .branch:
            return String(localized: "sidebar.filter.scope.branch", defaultValue: "branch")
        case .directory:
            return String(localized: "sidebar.filter.scope.directory", defaultValue: "path")
        case .group:
            return String(localized: "sidebar.filter.scope.group", defaultValue: "group")
        case .pullRequest:
            return String(localized: "sidebar.filter.scope.pullRequest", defaultValue: "pr")
        case .port:
            return String(localized: "sidebar.filter.scope.port", defaultValue: "port")
        }
    }
}
