public import Foundation
public import Observation

/// What the Stashed page needs from the App: the daemon's stashes and the
/// ops on them. Each call names a stash and the indexes of its tabs.
public protocol StashPageSource: AnyObject {
    /// Every stash, newest first.
    func stashes() async throws -> [StashedGroup]
    /// Reopens `tabs` of `group` (every tab for nil), where they were or in one new workspace.
    func restore(_ group: StashedGroup, tabs: [Int]?, inNewWorkspace: Bool) async throws
    /// Deletes `tabs` of `group` (the whole group for nil) for good.
    func delete(_ group: StashedGroup, tabs: [Int]?) async throws
    /// Imports OneTab groups as stashes.
    func importGroups(_ groups: [OneTabExport.Group]) async throws
}

/// The Stashed page's state (a native OneTab): the groups, newest first, and
/// the inline OneTab paste box. One model per app; every page view and the
/// New Tab page's link read it. Every op reloads the groups after it.
@Observable
public final class StashPageModel {
    public private(set) var groups: [StashedGroup] = []
    /// The inline paste box (Import from OneTab…): never a sheet.
    public var showsImport = false
    public var importText = ""
    /// The last op's failure or the import's outcome, shown inline under the header.
    public private(set) var notice: String?

    @ObservationIgnored public weak var source: (any StashPageSource)?
    @ObservationIgnored private var generation = 0

    public init(source: (any StashPageSource)? = nil) {
        self.source = source
    }

    /// Every tab in every group.
    public var tabCount: Int { groups.reduce(0) { $0 + $1.tabs.count } }

    /// Reads the groups again; a slower older read never replaces a newer one.
    public func reload() async {
        generation += 1
        let current = generation
        do {
            let loaded = try await source?.stashes() ?? []
            guard current == generation else { return }
            groups = loaded
        } catch {
            guard current == generation else { return }
            notice = String(describing: error)
        }
    }

    /// Restore All: every tab back where it was; the group goes.
    public func restore(_ group: StashedGroup) async { await run { try await $0.restore(group, tabs: nil, inNewWorkspace: false) } }

    /// Restore in New Workspace: every tab, in order, in one new workspace.
    public func restoreInNewWorkspace(_ group: StashedGroup) async {
        await run { try await $0.restore(group, tabs: nil, inNewWorkspace: true) }
    }

    /// A row's click: that tab back where it was.
    public func restore(_ group: StashedGroup, tab index: Int) async {
        await run { try await $0.restore(group, tabs: [index], inNewWorkspace: false) }
    }

    /// Deletes the whole group.
    public func delete(_ group: StashedGroup) async { await run { try await $0.delete(group, tabs: nil) } }

    /// A row's ×: that tab goes for good.
    public func delete(_ group: StashedGroup, tab index: Int) async { await run { try await $0.delete(group, tabs: [index]) } }

    /// Opens the paste box.
    public func showImport() {
        notice = nil
        showsImport = true
    }

    public func cancelImport() {
        showsImport = false
        importText = ""
    }

    /// Imports the pasted OneTab text; the box closes once it went through.
    public func importPasted() async {
        let export = OneTabExport(parsing: importText)
        guard !export.groups.isEmpty else {
            notice = StashStrings.importNothing
            return
        }
        guard let source else { return }
        do {
            try await source.importGroups(export.groups)
            notice = StashStrings.imported
            cancelImport()
        } catch {
            notice = String(describing: error)
        }
        await reload()
    }

    private func run(_ op: (any StashPageSource) async throws -> Void) async {
        guard let source else { return }
        notice = nil
        do { try await op(source) } catch { notice = String(describing: error) }
        await reload()
    }
}
