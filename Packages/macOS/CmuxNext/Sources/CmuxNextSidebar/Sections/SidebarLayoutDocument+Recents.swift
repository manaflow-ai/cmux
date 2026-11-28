import Foundation

// All chats used to be a sidebar section under the workspaces (`sec_recents`).
// It is now on the New Tab page only (Lawrence 2026-10-10, cx-n0i9). The id
// and contribution stay so a stored layout or another client that still
// names the section reads, and the sidebar leaves it out.
extension SidebarLayoutDocument {
    public nonisolated static let recentsSectionID = LayoutSectionID("sec_recents")
    public nonisolated static let recentsContribution = "cmux/agent-chats#recents"

    /// The layout the sidebar draws: without a stored All chats section.
    /// The stored document is not changed (no user data is removed).
    public nonisolated var withoutChats: SidebarLayoutDocument {
        var result = self
        result.sections.removeAll { $0.id == Self.recentsSectionID || $0.contribution == Self.recentsContribution }
        return result
    }

    /// Legacy layouts may still contain the section; the sidebar hides it.
    public nonisolated var recentsMigrationOps: [SidebarLayoutOp] { [] }
}
