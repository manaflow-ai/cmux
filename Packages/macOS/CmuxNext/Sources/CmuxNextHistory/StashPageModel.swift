public import AppKit
import CmuxNextDesign
public import CmuxNextWakeups
public import Observation

/// What the Stashed page needs from the App: the daemon's stashes and the
/// ops on them. Each call names a stash and its pages by their stable ids.
/// The model awaits these off the main thread (its op queue is a nonisolated task).
@MainActor public protocol StashPageSource: AnyObject, Sendable {
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
/// run one at a time (the page is disabled from the click until its op and
/// the reload after it land) and reload the groups after them. A delete hides
/// its pages at once and goes to the daemon when its Undo toast ends without Undo.
///
/// Recipe R-hop (plans/cmux-next/chrome-parity/p06-scheduler.md): a click's visible change (the page disabled,
/// the last failure cleared, a deleted row hidden) is made in the click's turn; the daemon call is awaited off
/// the main thread, and its end (the groups read again, the notice) is a ``BudgetedWorkClass/userBlocking`` main
/// task with a named owner. Chromium posts the reply of off-thread work to the UI thread as a typed task the same
/// way (`base::ThreadPool::PostTaskAndReplyWithResult`, content/browser/scheduler/browser_task_queues.h).
@Observable
public final class StashPageModel {
    /// The Stashed page's title, for its top page and tab.
    public static var title: String { StashStrings.title }

    /// The board owners of the model's main-thread ends.
    static let readOwner = "StashPage.read"
    static let restoreOwner = "StashPage.restore"
    static let deleteOwner = "StashPage.delete"
    static let importOwner = "StashPage.import"

    private var loaded: [StashedGroup] = []
    private var hiddenGroups: Set<String> = []
    private var hiddenTabs: Set<String> = []
    /// True from an op's click until it and its reload landed: the page's rows and buttons are disabled.
    public private(set) var isBusy = false
    /// The last op's failure or the import's outcome, shown inline under the header.
    public private(set) var notice: String?
    @ObservationIgnored private var noticeIsError = false
    /// Whether `notice` is a failed list read's, which the next good read clears.
    @ObservationIgnored private var noticeIsReadFailure = false

    @ObservationIgnored public weak var source: (any StashPageSource)?
    /// The app's one main-thread scheduler: every op's and read's main-thread end is a task on it.
    @ObservationIgnored private let mainWork: MainWorkScheduler
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// Ops clicked and not landed yet (``isBusy``).
    @ObservationIgnored private var inFlight = 0
    /// The newest `stash.list` read: an older read that lost to it waits for it.
    @ObservationIgnored private var latestRead: Task<Void, Never>?

    /// - Parameters:
    ///   - source: The daemon's stashes; held weakly.
    ///   - mainWork: The app's one main-thread scheduler (`AppServices.mainWork`).
    public init(source: (any StashPageSource)? = nil, mainWork: MainWorkScheduler) {
        self.source = source
        self.mainWork = mainWork
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
    ///
    /// - Parameter workClass: The class of the read's main-thread end: `visible` for a read nobody's input
    ///   caused (the page shows, another client changed a stash), `userBlocking` for the rest of a person's action.
    public func reload(_ workClass: BudgetedWorkClass = .visible) async {
        var awaited = startReload(workClass)
        await awaited.value
        while let newest = latestRead, newest != awaited {
            awaited = newest
            await newest.value
        }
    }

    /// Starts reading the groups again and returns at once (the page's show); the read is ``reload(_:)``'s.
    @discardableResult
    public func startReload(_ workClass: BudgetedWorkClass = .visible) -> Task<Void, Never> {
        beginRead(workClass, owner: Self.readOwner)
    }

    /// Starts one `stash.list` read off main; its result lands as one `workClass` main task, then `landed` runs
    /// in that task whether or not a newer read replaced it.
    @discardableResult
    private func beginRead(_ workClass: BudgetedWorkClass, owner: String,
                           then landed: (@MainActor @Sendable (StashPageModel) -> Void)? = nil) -> Task<Void, Never> {
        generation += 1
        let current = generation, source = source, mainWork = mainWork
        // task-owner: one stash.list read; `latestRead` keeps the newest so older callers await it. R-hop: the read
        // is awaited off main, its result is one main task of the caller's class.
        let read = Task { @concurrent [weak self] in
            let result: Result<[StashedGroup], any Error>
            do { result = .success(try await source?.stashes() ?? []) } catch { result = .failure(error) }
            await mainWork.apply(workClass, owner: owner) { [weak self] in
                guard let self else { return }
                self.land(result, current)
                landed?(self)
            }
        }
        latestRead = read
        return read
    }

    private func land(_ result: Result<[StashedGroup], any Error>, _ current: Int) {
        guard current == generation else { return }
        switch result {
        case .success(let read):
            loaded = read
            if noticeIsReadFailure { show(nil) }
        case .failure(let error):
            show(String(describing: error), error: true)
            noticeIsReadFailure = true
        }
    }

    /// Restore All: every tab back where it was; the group goes. Returns the op (nil with no source).
    @discardableResult
    public func restore(_ group: StashedGroup) -> Task<Void, Never>? {
        run(Self.restoreOwner) { try await $0.restore(group, tabs: group.tabs, inNewWorkspace: false) }
    }

    /// Restore in New Workspace: every tab, in order, in one new workspace.
    @discardableResult
    public func restoreInNewWorkspace(_ group: StashedGroup) -> Task<Void, Never>? {
        run(Self.restoreOwner) { try await $0.restore(group, tabs: group.tabs, inNewWorkspace: true) }
    }

    /// A row's click: that tab back where it was.
    @discardableResult
    public func restore(_ group: StashedGroup, tab: StashedGroup.Tab) -> Task<Void, Never>? {
        run(Self.restoreOwner) { try await $0.restore(group, tabs: [tab], inNewWorkspace: false) }
    }

    /// Delete Group (`tab` nil) or a row's ×. With `window`, the pages hide at once behind an
    /// Undo toast there and go for good when it ends without Undo (nil: the op starts then); else they go now.
    @discardableResult
    public func delete(_ group: StashedGroup, tab: StashedGroup.Tab? = nil, undoIn window: NSWindow? = nil) -> Task<Void, Never>? {
        let tabs = tab.map { [$0] }
        guard let window else {
            return run(Self.deleteOwner) { try await $0.delete(group, tabs: tabs) }
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
            // The model's op queue (`tail`) orders it; the pages show again only once the reload after it landed.
            self.run(Self.deleteOwner, { try await $0.delete(group, tabs: tabs) }, then: { model, _ in
                if let tab { model.hiddenTabs.remove(tab.id) } else { model.hiddenGroups.remove(group.id) }
            })
        }
        return nil
    }

    /// Imports `draft`'s pasted OneTab text. The box closes once pages were imported; with
    /// none, it stays open with the notice. Returns the op (nil when nothing parsed or with no source).
    @discardableResult
    public func importPasted(_ draft: StashImportDraft) -> Task<Void, Never>? {
        let export = OneTabExport(parsing: draft.text)
        guard !export.groups.isEmpty else {
            show(StashStrings.importNothing, error: true)
            return nil
        }
        let groups = export.groups
        return run(Self.importOwner, { try await $0.importGroups(groups) }, then: { model, counts in
            model.show(StashStrings.imported(counts.imported, skipped: counts.skipped), error: counts.imported == 0)
            if counts.imported > 0 { draft.close() }
        })
    }

    private func show(_ text: String?, error: Bool = false) {
        notice = text
        noticeIsError = error && text != nil
        noticeIsReadFailure = false
    }

    /// Runs `op` after every op before it, then reloads the groups, then `finish` with its value (its failure
    /// becomes the notice). The page shows the op in this turn: disabled, the last failure cleared.
    @discardableResult
    private func run<Value: Sendable>(_ owner: String, _ op: @escaping @Sendable (any StashPageSource) async throws -> Value,
                                      then finish: @escaping @MainActor @Sendable (StashPageModel, Value) -> Void = { _, _ in })
        -> Task<Void, Never>? {
        guard let source else { return nil }
        inFlight += 1
        isBusy = true
        if noticeIsError { show(nil) }
        let previous = tail, mainWork = mainWork
        // task-owner: the model's op queue (`tail`); each op waits for the one before it and ends with its reload.
        // R-hop: the daemon call is awaited off main; its end (the reload, then the notice) is userBlocking main tasks.
        let task = Task { @concurrent [weak self] in
            await previous?.value
            let result: Result<Value, any Error>
            do { result = .success(try await op(source)) } catch { result = .failure(error) }
            let read = await mainWork.apply(.userBlocking, owner: owner) { [weak self] () -> Task<Void, Never>? in
                self?.beginRead(.userBlocking, owner: owner) { $0.end(result, finish) }
            }
            await read?.value
        }
        tail = task
        return task
    }

    /// An op's end, after the reload it started landed: the page is enabled again once no op is left.
    private func end<Value>(_ result: Result<Value, any Error>, _ finish: @MainActor (StashPageModel, Value) -> Void) {
        inFlight -= 1
        isBusy = inFlight > 0
        switch result {
        case .success(let value): finish(self, value)
        case .failure(let error): show(String(describing: error), error: true)
        }
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
