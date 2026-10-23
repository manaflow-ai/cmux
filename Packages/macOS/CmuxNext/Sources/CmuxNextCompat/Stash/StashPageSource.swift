/// What the Stashed page needs from the App: the daemon's stashes and the
/// ops on them. Each call names a stash and its pages by their stable ids.
/// Main-actor, as the page's model that calls it (this core target has no default isolation).
@MainActor
public protocol StashPageSource: AnyObject {
    /// Every stash, newest first.
    func stashes() async throws -> [StashedGroup]
    /// Reopens `tabs` of `group`, where they were or in one new workspace, and shows them.
    func restore(_ group: StashedGroup, tabs: [StashedGroup.Tab], inNewWorkspace: Bool) async throws
    /// Deletes `tabs` of `group` (the whole group for nil) for good.
    func delete(_ group: StashedGroup, tabs: [StashedGroup.Tab]?) async throws
    /// Imports OneTab groups as stashes; returns the pages imported and skipped.
    func importGroups(_ groups: [OneTabExport.Group]) async throws -> (imported: Int, skipped: Int)
}
