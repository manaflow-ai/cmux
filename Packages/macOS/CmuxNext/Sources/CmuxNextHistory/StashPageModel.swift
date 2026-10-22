public import AppKit
import CmuxNextDesign
public import Observation

/// What the Stashed page needs from the App: the daemon's stashes and the
/// ops on them. Each call names a stash and its pages by their stable ids.
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

/// The Stashed page's state (a native OneTab): the groups, newest first. One
/// model per app; every page view and the New Tab page's link read it. Ops
/// run one at a time (the page is disabled while one is in flight) and
/// reload the groups after them. A delete hides its pages at once and goes
/// to the daemon when its Undo toast ends without Undo.
@Observable
public final class StashPageModel {
    /// The Stashed page's title, for its top page and tab.
    public static var title: String { StashStrings.title }

    private var loaded: [StashedGroup] = []
    private var hiddenGroups: Set<String> = []
    private var hiddenTabs: Set<String> = []
    /// True while an op is in flight: the page's rows and buttons are disabled.
    public private(set) var isBusy = false
    /// The last op's failure or the import's outcome, shown inline under the header.
    public private(set) var notice: String?
    @ObservationIgnored private var noticeIsError = false
    /// Whether `notice` is a failed list read's, which the next good read clears.
    @ObservationIgnored private var noticeIsReadFailure = false

    @ObservationIgnored public weak var source: (any StashPageSource)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// The newest `stash.list` read: an older read that lost to it waits for it.
    @ObservationIgnored private var latestRead: Task<Void, Never>?

    public init(source: (any StashPageSource)? = nil) {
        self.source = source
    }

    /// The groups, without pages whose delete waits on its Undo toast.
    public var groups: [StashedGroup] {
        loaded.compactMap { group in
            guard !hiddenGroups.contains(group.id) else { return nil }
            var shown = group
            shown.tabs.removeAll { hiddenTabs.contains($0.id) }
            return shown.tabs.isEmpty ? nil : shown
        }
    }

    /// Every tab in every group.
    public var tabCount: Int { groups.reduce(0) { $0 + $1.tabs.count } }

    /// The groups whose members match `query`: a page's title or address, a workspace's name, tab title or address, or the group's name
    /// (which keeps all its pages), ignoring case and diacritics. Every group for a blank query.
    public func groups(matching query: String) -> [StashedGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        func matches(_ text: String?) -> Bool { text?.localizedStandardContains(query) == true }
        return groups.compactMap { group in
            if matches(group.name) { return group }
            var shown = group
            shown.tabs.removeAll { tab in
                !(matches(tab.title) || matches(tab.url) || (tab.workspaceTabs + tab.workspaceAddresses).contains { matches($0) })
            }
            return shown.tabs.isEmpty ? nil : shown
        }
    }

    /// Reads the groups again; a slower older read never replaces a newer one, and returns once
    /// the newest read has landed (a stash change event may start one while this one runs). A
    /// good read clears a failed read's notice, never an action's (a failed restore stays said).
    public func reload() async {
        generation += 1
        let current = generation
        // task-owner: one stash.list read; `latestRead` keeps the newest so older callers await it.
        let read = Task<Void, Never> { @MainActor [weak self] in await self?.read(current) }
        latestRead = read
        var awaited = read
        await read.value
        while let newest = latestRead, newest != awaited {
            awaited = newest
            await newest.value
        }
    }

    private func read(_ current: Int) async {
        do {
            let read = try await source?.stashes() ?? []
            guard current == generation else { return }
            loaded = read
            if noticeIsReadFailure { show(nil) }
        } catch {
            guard current == generation else { return }
            show(String(describing: error), error: true)
            noticeIsReadFailure = true
        }
    }

    /// Restore All: every tab back where it was; the group goes.
    public func restore(_ group: StashedGroup) async {
        await run { try await $0.restore(group, tabs: group.tabs, inNewWorkspace: false) }
    }

    /// Restore in New Workspace: every tab, in order, in one new workspace.
    public func restoreInNewWorkspace(_ group: StashedGroup) async {
        await run { try await $0.restore(group, tabs: group.tabs, inNewWorkspace: true) }
    }

    /// A row's click: that tab back where it was.
    public func restore(_ group: StashedGroup, tab: StashedGroup.Tab) async {
        await run { try await $0.restore(group, tabs: [tab], inNewWorkspace: false) }
    }

    /// Delete Group (`tab` nil) or a row's ×. With `window`, the pages hide at once behind an
    /// Undo toast there and go for good when it ends without Undo; else they go now.
    public func delete(_ group: StashedGroup, tab: StashedGroup.Tab? = nil, undoIn window: NSWindow? = nil) async {
        let tabs = tab.map { [$0] }
        guard let window else {
            await run { try await $0.delete(group, tabs: tabs) }
            return
        }
        if let tab { hiddenTabs.insert(tab.id) } else { hiddenGroups.insert(group.id) }
        let message = tab == nil ? StashStrings.deletedGroup : StashStrings.deletedTab
        let toast = CmuxToast(id: "stash.delete.\(group.id).\(tab?.id ?? "all")", message: message, action: .undo())
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = { [weak self] in
            if let tab { self?.hiddenTabs.remove(tab.id) } else { self?.hiddenGroups.remove(group.id) }
        }
        handle.onDismiss = { [weak self] reason in
            guard reason != .action, let self else { return }
            // task-owner: the model's op queue (`tail`) orders it; it ends with the delete.
            Task { @MainActor in
                await self.run { try await $0.delete(group, tabs: tabs) }
                if let tab { self.hiddenTabs.remove(tab.id) } else { self.hiddenGroups.remove(group.id) }
            }
        }
    }

    /// Imports `draft`'s pasted OneTab text. The box closes once pages were imported; with
    /// none, it stays open with the notice.
    public func importPasted(_ draft: StashImportDraft) async {
        let export = OneTabExport(parsing: draft.text)
        guard !export.groups.isEmpty else {
            show(StashStrings.importNothing, error: true)
            return
        }
        await run { [weak self] source in
            let (imported, skipped) = try await source.importGroups(export.groups)
            self?.show(StashStrings.imported(imported, skipped: skipped), error: imported == 0)
            if imported > 0 { draft.close() }
        }
    }

    private func show(_ text: String?, error: Bool = false) {
        notice = text
        noticeIsError = error && text != nil
        noticeIsReadFailure = false
    }

    /// Runs `op` after every op before it, then reloads the groups.
    private func run(_ op: @escaping @MainActor (any StashPageSource) async throws -> Void) async {
        let previous = tail
        // task-owner: the model's op queue; each op waits for the one before it.
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, let source = self.source else { return }
            self.isBusy = true
            if self.noticeIsError { self.show(nil) }
            do { try await op(source) } catch { self.show(String(describing: error), error: true) }
            await self.reload()
            self.isBusy = false
        }
        tail = task
        await task.value
    }
}

/// One Stashed page's own state: its search text, and its OneTab paste box (Import from
/// OneTab…), inline, never a sheet, its own per window. The box closes when its page closes.
@Observable
public final class StashImportDraft {
    public var isOpen = false
    public var text = ""
    /// The page's search text (``StashPageModel/groups(matching:)``).
    public var query = ""

    public init() {}

    public func open() { isOpen = true }

    public func close() {
        isOpen = false
        text = ""
    }
}

extension URL {
    /// The Stashed Tabs page's address, `cmux://stashed` (with or without a trailing slash, query
    /// or fragment): typed in the address bar or opened as a link, it shows the page.
    public nonisolated var isStashedPage: Bool {
        scheme?.lowercased() == "cmux" && host()?.lowercased() == "stashed"
    }
}
