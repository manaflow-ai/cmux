import Foundation

// Chats: the device-wide agent chats under the workspaces. The section is
// opt-in through `sidebar.showChats`; the shared id and contribution remain
// stable so stored layouts and other clients can refer to it.
extension SidebarLayoutDocument {
    public nonisolated static let recentsSectionID = LayoutSectionID("sec_recents")
    public nonisolated static let recentsContribution = "cmux/agent-chats#recents"

    /// The Recents section: titled by the App, below the workspaces.
    public nonisolated static let recentsSection = LayoutSection(id: recentsSectionID, region: .middle, look: .list, content: .app,
                                                                 contribution: recentsContribution)

    /// Returns the client-visible layout for the Chats visibility setting.
    /// The setting is client-owned, so toggling it does not write a layout op.
    public nonisolated func chatsLayout(enabled: Bool) -> SidebarLayoutDocument {
        var result = self
        result.sections.removeAll { $0.id == Self.recentsSectionID }
        guard enabled else { return result }
        let middle = result.sections.filter { $0.region == .middle }
        let index = (middle.firstIndex { $0.content == .workspaces } ?? middle.count - 1) + 1
        result.sections.insert(Self.recentsSection, at: result.sections.firstIndex { $0.region == .middle && $0.content == .workspaces }.map { $0 + 1 } ?? index)
        return result
    }

    /// Legacy layouts may still contain the section; visibility is now controlled by the setting.
    public nonisolated var recentsMigrationOps: [SidebarLayoutOp] { [] }
}
