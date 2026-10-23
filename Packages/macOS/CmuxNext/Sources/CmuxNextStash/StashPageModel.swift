public import Observation

/// The Stashed page's state (a native OneTab): the groups, newest first. One
/// model per app; every page view and the New Tab page's link read it. Ops
/// run one at a time (the page is disabled while one is in flight) and
/// reload the groups after them. A delete from the page hides its pages at
/// once and goes to the daemon when its Undo toast ends without Undo (the
/// toast, the page's title and its import notices are the page's own, in
/// CmuxNextHistory's `StashPageModel+Page.swift`).
@Observable
public final class StashPageModel {
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
            if noticeIsReadFailure { showNotice(nil) }
        } catch {
            guard current == generation else { return }
            showNotice(String(describing: error), error: true)
            noticeIsReadFailure = true
        }
    }

    /// Restore All: every tab back where it was; the group goes.
    public func restore(_ group: StashedGroup) async {
        await perform { try await $0.restore(group, tabs: group.tabs, inNewWorkspace: false) }
    }

    /// Restore in New Workspace: every tab, in order, in one new workspace.
    public func restoreInNewWorkspace(_ group: StashedGroup) async {
        await perform { try await $0.restore(group, tabs: group.tabs, inNewWorkspace: true) }
    }

    /// A row's click: that tab back where it was.
    public func restore(_ group: StashedGroup, tab: StashedGroup.Tab) async {
        await perform { try await $0.restore(group, tabs: [tab], inNewWorkspace: false) }
    }

    /// Delete Group (`tab` nil) or a row's ×, for good now.
    public func delete(_ group: StashedGroup, tab: StashedGroup.Tab? = nil) async {
        let tabs = tab.map { [$0] }
        await perform { try await $0.delete(group, tabs: tabs) }
    }

    /// Hides `tab` of `group` (the whole group for nil) from ``groups`` while its delete waits on
    /// an Undo toast.
    public func hide(_ group: StashedGroup, tab: StashedGroup.Tab?) {
        if let tab { hiddenTabs.insert(tab.id) } else { hiddenGroups.insert(group.id) }
    }

    /// Shows `tab` of `group` (the whole group for nil) again: its Undo, or its delete went through.
    public func unhide(_ group: StashedGroup, tab: StashedGroup.Tab?) {
        if let tab { hiddenTabs.remove(tab.id) } else { hiddenGroups.remove(group.id) }
    }

    /// Shows `text` inline under the header (nil clears it). An `error` notice goes at the next op.
    public func showNotice(_ text: String?, error: Bool = false) {
        notice = text
        noticeIsError = error && text != nil
        noticeIsReadFailure = false
    }

    /// Runs `op` on the source after every op before it, then reloads the groups. A thrown error
    /// is the notice.
    public func perform(_ op: @escaping @MainActor (any StashPageSource) async throws -> Void) async {
        let previous = tail
        // task-owner: the model's op queue; each op waits for the one before it.
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, let source = self.source else { return }
            self.isBusy = true
            if self.noticeIsError { self.showNotice(nil) }
            do { try await op(source) } catch { self.showNotice(String(describing: error), error: true) }
            await self.reload()
            self.isBusy = false
        }
        tail = task
        await task.value
    }
}
