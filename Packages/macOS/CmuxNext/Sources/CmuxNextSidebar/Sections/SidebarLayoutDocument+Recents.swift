import Foundation

// Recents: the recent agent chats under the workspaces, as the ChatGPT
// desktop app lists Recents under Projects. The App draws the section
// (`SidebarRecentsView`). A stored layout equal to a default from before
// Recents gains it through an ordinary op; a layout the user changed keeps
// its sections.
extension SidebarLayoutDocument {
    public nonisolated static let recentsSectionID = LayoutSectionID("sec_recents")
    public nonisolated static let recentsContribution = "cmux/agent-chats#recents"

    /// The Recents section: titled by the App, below the workspaces.
    public nonisolated static let recentsSection = LayoutSection(id: recentsSectionID, region: .middle, look: .list, content: .app,
                                                                 contribution: recentsContribution)

    /// Adds Recents after the workspaces to a layout that equals a default
    /// from before it (with or without CodeRouter on top), or none.
    public nonisolated var recentsMigrationOps: [SidebarLayoutOp] {
        guard section(Self.recentsSectionID) == nil else { return [] }
        let earlier = [Self.defaults, Self.migrationTarget].map { $0.sections.filter { $0.id != Self.recentsSectionID } }
        guard earlier.contains(sections) else { return [] }
        let middle = sections.filter { $0.region == .middle }
        let index = (middle.firstIndex { $0.content == .workspaces } ?? middle.count - 1) + 1
        return [.sectionAdd(Self.recentsSection, index: index)]
    }
}
