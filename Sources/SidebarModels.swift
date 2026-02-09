import Foundation

// Sidebar metadata types used by shell integration + control socket commands.

struct SidebarStatusEntry: Identifiable {
    let id = UUID()
    let key: String
    var value: String
    var icon: String?
    var color: String?
    var timestamp: Date
}

enum SidebarLogLevel: String {
    case info, progress, success, warning, error
}

struct SidebarLogEntry: Identifiable {
    let id = UUID()
    let message: String
    let level: SidebarLogLevel
    let source: String?
    let timestamp: Date
}

