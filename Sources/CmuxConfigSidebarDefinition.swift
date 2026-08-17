import Foundation

/// Sidebar behavior configured in `cmux.json`.
struct CmuxConfigSidebarDefinition: Codable, Sendable, Equatable {
    var sessionStatusGroups: [CmuxSessionStatusGroupDefinition]?
}
