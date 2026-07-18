import CmuxSettings
import CmuxSidebar
import Foundation

/// Immutable presentation for one workspace status row shared by both sidebar renderers.
struct SidebarWorkspaceStatusRowContent: Equatable, Identifiable {
    let entry: SidebarStatusEntry
    let text: String

    var id: String { entry.key }
    var icon: String? { entry.icon }
    var color: String? { entry.color }
    var url: URL? { entry.url }
    var format: SidebarMetadataFormat { entry.format }

    init(entry: SidebarStatusEntry) {
        self.entry = entry
        let trimmedValue = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        text = trimmedValue.isEmpty ? Self.fallbackText(for: entry.key) : trimmedValue
    }

    private static func fallbackText(for key: String) -> String {
        guard AgentHibernationLifecycleStatusKeys.isAllowed(key) else { return key }
        let catalogSlug = key == "claude_code" ? "claude" : key
        return AutoNamingAgentCatalog.displayName(forSlug: catalogSlug)
    }
}
