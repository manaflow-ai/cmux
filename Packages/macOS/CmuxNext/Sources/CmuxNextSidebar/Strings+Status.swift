import Foundation

extension Strings {
    /// Group by Status's header names (`SidebarStatusBucket`).
    static func statusBucket(_ bucket: SidebarStatusBucket) -> String {
        switch bucket {
        case .needsYou: String(localized: "sidebar.status.needsYou", defaultValue: "Needs you", bundle: .module)
        case .working: String(localized: "sidebar.status.working", defaultValue: "Working", bundle: .module)
        case .done: String(localized: "sidebar.status.done", defaultValue: "Done", bundle: .module)
        case .noAgent: String(localized: "sidebar.status.noAgent", defaultValue: "No agent", bundle: .module)
        }
    }
}
