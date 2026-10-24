import CoreGraphics
import Foundation

/// App-wide window membership and lifecycle (plans/cmux-next/REWRITE.md
/// "Tab drag", user feedback 2026-09-29): which workspaces each window's
/// sidebar shows, and which windows exist. Everything else a window has
/// (selected workspace, sidebar width, focus, screen switcher) is that
/// window's own `WindowState`.
///
/// Invariants: a window exists only while it owns at least one workspace
/// (user decision 2026-09-30: no "No workspaces in this window" state);
/// every workspace is owned by at most one window, and every live workspace
/// by exactly one after `reconcile`. Every transition that takes a window's
/// last workspace (close, move, tear-off, daemon removal) removes that
/// window in the same step, the only window too; no window is registered
/// without a workspace. Closing a window never ends terminals: it stays
/// registered (closed, still owning its workspaces) as one closed group that
/// Cmd-Shift-T, History, a Dock click or relaunch restores (cx-gzh.9.3). On a
/// daemon without window records (no closed group) a non-last window's
/// workspaces move to the most recent other open window instead.
///
/// Incognito windows (user decision 2026-09-30) are their own kind: no
/// workspace moves between an incognito window and a normal one (moves and
/// tear-offs across kinds are refused, a tear-off from an incognito window
/// is incognito, orphans and a closed window's workspaces go to a window of
/// their kind only), closing one discards its workspaces instead of handing
/// them over, and they are never saved.
///
/// Pure value type: every transition is a mutating method returning the
/// `Changes` the App animates. `WindowManager` applies them to controllers.
struct WindowRegistry: Equatable, Sendable {
    struct Window: Equatable, Sendable, Identifiable {
        let id: String
        /// Owned workspace ids (`WorkspaceModel.id`), in daemon sidebar
        /// order as of the last membership transition. Never empty for a
        /// registered window. The daemon owns the order; this mirrors it when
        /// membership changes, not on every move (the sidebar draws its own
        /// order): a move must not cost a pass over every workspace.
        var workspaceIDs: [String]
        /// AppKit screen frame (bottom-left origin).
        var frame: CGRect?
        /// Display the window was on (`CGDisplayCreateUUIDFromDisplayID`).
        var display: String?
        /// False after the user closed it: kept so its workspaces stay
        /// restorable (one closed group).
        var isOpen = true

        init(id: String, workspaceIDs: [String] = [], frame: CGRect? = nil, display: String? = nil, isOpen: Bool = true) {
            self.id = id
            self.workspaceIDs = workspaceIDs
            self.frame = frame
            self.display = display
            self.isOpen = isOpen
        }
    }

    /// What a transition did, for animation and focus.
    struct Changes: Equatable, Sendable {
        /// Windows removed because they lost their last workspace.
        var emptied: [String] = []
        /// Workspaces whose owner changed, by new owner.
        var moved: [String: [String]] = [:]
        /// Workspaces of a closed incognito window: no window lists them
        /// any more, and the caller closes them.
        var discarded: [String] = []

        var isEmpty: Bool { emptied.isEmpty && moved.isEmpty && discarded.isEmpty }
    }

    /// Creation order. A write that changes membership rebuilds `owners`
    /// (O(n)); loops that touch several windows write a local copy back once.
    /// A frame or open-state change compares O(windows) (equal arrays share
    /// storage) and rebuilds nothing.
    private(set) var windows: [Window] = [] {
        didSet {
            let same = windows.count == oldValue.count
                && zip(windows, oldValue).allSatisfy { $0.id == $1.id && $0.workspaceIDs == $1.workspaceIDs }
            if !same { owners = Self.ownerIndex(windows) }
        }
    }
    /// Owning window by workspace id (the first window that lists it), so
    /// `owner(of:)` is O(1): reconcile asks it once per live workspace, which
    /// was O(n²) at 1,000 workspaces (a watchdog trip). Derived from
    /// `windows`; not part of `==`.
    private var owners: [String: String] = [:]
    /// Window ids, front first: key changes and `WindowActivation` orders keep it (`WindowManager.windowDidOrder`).
    private(set) var recency: [String] = []
    /// Incognito windows, registered or about to be (New Incognito Window
    /// marks the id before its workspace is reported).
    private(set) var incognito: Set<String> = []
    /// Workspaces of closed incognito windows until the daemons stop
    /// reporting them: reconcile never gives them to a window.
    private(set) var discarding: Set<String> = []

    init(windows: [Window] = []) {
        self.windows = windows
        owners = Self.ownerIndex(windows)
        recency = windows.map(\.id)
    }

    static func == (lhs: WindowRegistry, rhs: WindowRegistry) -> Bool {
        lhs.windows == rhs.windows && lhs.recency == rhs.recency && lhs.incognito == rhs.incognito
            && lhs.discarding == rhs.discarding
    }

    private static func ownerIndex(_ windows: [Window]) -> [String: String] {
        var owners: [String: String] = [:]
        owners.reserveCapacity(windows.reduce(0) { $0 + $1.workspaceIDs.count })
        for window in windows {
            for id in window.workspaceIDs where owners[id] == nil { owners[id] = window.id }
        }
        return owners
    }

    // MARK: Queries

    func window(_ id: String) -> Window? { windows.first { $0.id == id } }

    func owner(of workspaceID: String) -> String? { owners[workspaceID] }

    var openWindows: [Window] { windows.filter(\.isOpen) }

    /// The most recently active open window, excluding `excluded`.
    /// `incognito` picks the kind: normal windows unless true.
    func mostRecentOpen(excluding excluded: Set<String> = [], incognito wanted: Bool = false) -> String? {
        let open = Set(openWindows.map(\.id).filter { isIncognito($0) == wanted }).subtracting(excluded)
        return recency.first { open.contains($0) } ?? windows.first { open.contains($0.id) }?.id
    }

    func isIncognito(_ windowID: String) -> Bool { incognito.contains(windowID) }

    /// True when moving `workspaceIDs` into window `id` would cross between
    /// an incognito window and a normal one (a workspace no window lists
    /// crosses nothing).
    func crossesIncognito(_ workspaceIDs: [String], to id: String) -> Bool {
        let target = isIncognito(id)
        return workspaceIDs.contains { owner(of: $0).map { isIncognito($0) != target } ?? false }
    }

    /// Descriptions of broken invariants (empty when consistent).
    func violations() -> [String] {
        var seen: [String: String] = [:]
        var problems: [String] = []
        for window in windows {
            for id in window.workspaceIDs {
                if let other = seen[id] { problems.append("\(id) owned by \(other) and \(window.id)") }
                seen[id] = window.id
            }
        }
        if Set(windows.map(\.id)).count != windows.count { problems.append("duplicate window ids") }
        if Set(recency) != Set(windows.map(\.id)) || recency.count != windows.count { problems.append("recency out of sync") }
        for window in windows where window.workspaceIDs.isEmpty {
            problems.append("\(window.id) has no workspaces")
        }
        return problems
    }

    // MARK: Lifecycle

    /// Registers a new open window owning `workspaceIDs` (taken from their
    /// current owners) and makes it the most recent; a window opened
    /// `behind` the others (never key) is the least recent instead, so the
    /// key window stays first (cx-ppw2w). With no workspaces
    /// nothing is registered: a window without one does not exist.
    /// Workspaces taken from incognito windows make the new window
    /// incognito; a mix of both kinds, or normal workspaces for a window
    /// marked incognito, opens nothing.
    @discardableResult
    mutating func openWindow(id: String, workspaceIDs: [String] = [], frame: CGRect? = nil, display: String? = nil,
                             behind: Bool = false) -> Changes {
        guard window(id) == nil else { return move(workspaceIDs, to: id) }
        guard !workspaceIDs.isEmpty else { return Changes() }
        let kinds = Set(workspaceIDs.compactMap { owner(of: $0).map(isIncognito) })
        if kinds.count > 1 || (isIncognito(id) && kinds == [false]) { return Changes() }
        if kinds == [true] { incognito.insert(id) }
        var changes = Changes()
        let taken = detach(workspaceIDs)
        windows.append(Window(id: id, workspaceIDs: taken, frame: frame, display: display))
        if behind { recency.append(id) } else { recency.insert(id, at: 0) }
        changes.moved[id] = taken
        changes.emptied = closeEmptied()
        return changes
    }

    /// The user closed `id`. A normal window closes like a browser window
    /// (cx-gzh.9.3): kept, closed, with its workspaces (still running), as one
    /// closed `window` group that Cmd-Shift-T reopens whole. With `keepsGroup`
    /// false (no window records, so no group) a non-last window's workspaces
    /// move to the most recent other open window. An incognito window closes
    /// for good, and its workspaces are `discarded`.
    @discardableResult
    mutating func close(_ id: String, keepsGroup: Bool = true) -> Changes {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return Changes() }
        if isIncognito(id) {
            var changes = Changes()
            changes.discarded = windows[index].workspaceIDs
            discarding.formUnion(changes.discarded)
            remove(id)
            return changes
        }
        if !keepsGroup, let heir = mostRecentOpen(excluding: [id]) {
            return merge(id, into: heir)
        }
        windows[index].isOpen = false
        activate(id) // a Dock click or a relaunch brings back the last window closed
        return Changes()
    }

    /// Closed window `id`'s group was deleted: its workspaces move to the most
    /// recent open window of its kind, else it opens again (never hidden).
    @discardableResult
    mutating func releaseClosed(_ id: String) -> Changes {
        guard let window = window(id), !window.isOpen else { return Changes() }
        guard let heir = mostRecentOpen(excluding: [id], incognito: isIncognito(id)) else {
            _ = reopen(id: id)
            return Changes()
        }
        return merge(id, into: heir)
    }

    /// Moves every workspace of `id` into `heir` and removes `id`.
    private mutating func merge(_ id: String, into heir: String) -> Changes {
        var changes = Changes()
        let orphans = window(id)?.workspaceIDs ?? []
        remove(id)
        if !orphans.isEmpty, let heirIndex = windows.firstIndex(where: { $0.id == heir }) {
            windows[heirIndex].workspaceIDs += orphans
            changes.moved[heir] = orphans
        }
        return changes
    }

    /// Opens the most recent closed window again (Dock click, Show cmux).
    /// Returns its id, or nil when none is closed.
    mutating func reopen() -> String? {
        guard let id = recency.first(where: { id in window(id)?.isOpen == false && !isIncognito(id) }),
              let index = windows.firstIndex(where: { $0.id == id }) else { return nil }
        windows[index].isOpen = true
        activate(id)
        return id
    }

    /// Marks restored window `id` open or closed (a relaunch keeps a closed
    /// window closed, `WindowRecord.isClosed`).
    mutating func setRestored(_ id: String, open: Bool) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].isOpen = open
    }

    /// Opens closed window `id` again (Reopen Closed of its `window` group).
    /// False when it is not a closed window of this app.
    mutating func reopen(id: String) -> Bool {
        guard let index = windows.firstIndex(where: { $0.id == id }), !windows[index].isOpen else { return false }
        windows[index].isOpen = true
        activate(id)
        return true
    }

    mutating func activate(_ id: String) {
        guard window(id) != nil else { return }
        recency.removeAll { $0 == id }
        recency.insert(id, at: 0)
    }

    /// Window `id` was ordered in behind the app's other windows.
    mutating func moveToBack(_ id: String) { if window(id) != nil { recency.removeAll { $0 == id }; recency.append(id) } }

    mutating func setGeometry(_ id: String, frame: CGRect?, display: String?) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].frame = frame
        if let display { windows[index].display = display }
    }

    // MARK: Membership

    /// Moves `workspaceIDs` into window `id`, before `anchor` when it is
    /// already there (else appended). Windows left empty close.
    @discardableResult
    /// Nothing moves across incognito and normal windows (`crossesIncognito`).
    mutating func move(_ workspaceIDs: [String], to id: String, before anchor: String? = nil) -> Changes {
        guard window(id) != nil, !workspaceIDs.isEmpty, !crossesIncognito(workspaceIDs, to: id) else { return Changes() }
        var changes = Changes()
        let taken = detach(workspaceIDs)
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return changes }
        let slot = anchor.flatMap { windows[index].workspaceIDs.firstIndex(of: $0) } ?? windows[index].workspaceIDs.endIndex
        windows[index].workspaceIDs.insert(contentsOf: taken, at: slot)
        changes.moved[id] = taken
        changes.emptied = closeEmptied()
        return changes
    }

    /// Brings membership in line with the daemons: drops `dead` workspaces
    /// (known gone; a workspace whose machine is still connecting is not
    /// dead, so its window survives relaunch), orders each window like
    /// `live`, and gives orphans (created by a drag, the CLI, another
    /// device) to their `placements` window: an open one takes it, an
    /// unregistered one opens with it (a new window waiting for the
    /// workspace it was created for, so it never shows empty). Other orphans
    /// go to the most recent open window, else the most recent (closed)
    /// one, else `fallbackWindow`. `held` orphans stay unowned this time.
    /// A new placement window in `behind` opens behind the others, so it is
    /// the least recent (cx-ppw2w). Windows left empty close.
    @discardableResult
    mutating func reconcile(live: [String], dead: Set<String>, placements: [String: String] = [:], held: Set<String> = [],
                            behind: Set<String> = [], fallbackWindow: @autoclosure () -> String) -> Changes {
        var changes = Changes()
        let rank = Dictionary(live.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var pruned = windows
        for index in pruned.indices {
            pruned[index].workspaceIDs = pruned[index].workspaceIDs.filter { !dead.contains($0) }.merged(adding: [], rank: rank)
        }
        windows = pruned
        discarding = discarding.intersection(live).subtracting(dead)
        let owned = Set(owners.keys).union(discarding)
        // Each heir takes its orphans in one merge (one sort per window, not
        // one per orphan); the result is the same, every orphan is ranked.
        var heirs: [String] = []
        for orphan in live where !owned.contains(orphan) && !held.contains(orphan) {
            let claimed = placements[orphan].flatMap { placementWindow($0, behind: behind.contains($0)) }
            let heir = claimed ?? mostRecentOpen() ?? recency.first { !isIncognito($0) } ?? register(fallbackWindow())
            guard window(heir) != nil else { continue }
            if changes.moved[heir] == nil { heirs.append(heir) }
            changes.moved[heir, default: []].append(orphan)
        }
        if !heirs.isEmpty {
            var grown = windows
            for heir in heirs {
                guard let index = grown.firstIndex(where: { $0.id == heir }), let orphans = changes.moved[heir] else { continue }
                grown[index].workspaceIDs = grown[index].workspaceIDs.merged(adding: orphans, rank: rank)
            }
            windows = grown
        }
        changes.emptied = closeEmptied()
        return changes
    }

    /// Orders each window's workspaces like `live` (the daemons' order);
    /// workspaces not in it keep their place after the ordered ones.
    mutating func order(like live: [String]) {
        let rank = Dictionary(live.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered = windows
        for index in ordered.indices { ordered[index].workspaceIDs = ordered[index].workspaceIDs.merged(adding: [], rank: rank) }
        if ordered != windows { windows = ordered }
    }

    // MARK: Internals

    /// Removes `ids` from every window; returns them in the given order,
    /// without duplicates.
    private mutating func detach(_ ids: [String]) -> [String] {
        var unique: [String] = []
        var set = Set<String>()
        for id in ids where set.insert(id).inserted { unique.append(id) }
        var detached = windows
        for index in detached.indices { detached[index].workspaceIDs.removeAll { set.contains($0) } }
        windows = detached
        return unique
    }

    private mutating func remove(_ id: String) {
        windows.removeAll { $0.id == id }
        recency.removeAll { $0 == id }
        incognito.remove(id)
    }

    /// Workspaces of incognito windows from a run that ended without
    /// closing them (a crash): no window takes them while they close.
    mutating func markDiscarding(_ ids: [String]) {
        discarding.formUnion(ids)
    }

    /// Marks window `id` incognito: a registered window, or the id New
    /// Incognito Window claims its first workspace for.
    mutating func markIncognito(_ id: String) {
        incognito.insert(id)
    }

    /// The window a claimed orphan goes to: its window when open, or a new
    /// open window with that id when none is registered. A claim on a
    /// closed window falls through to the usual heir.
    private mutating func placementWindow(_ id: String, behind: Bool) -> String? {
        guard let existing = window(id) else { return register(id, behind: behind) }
        return existing.isOpen ? id : nil
    }

    /// Registers open window `id`, most recent (least recent when it opens
    /// `behind`). Its caller gives it a workspace in the same transition;
    /// `closeEmptied` removes it otherwise.
    private mutating func register(_ id: String, behind: Bool = false) -> String {
        windows.append(Window(id: id))
        if behind { recency.append(id) } else { recency.insert(id, at: 0) }
        return id
    }

    /// Removes every window left with no workspace (the only one too).
    private mutating func closeEmptied() -> [String] {
        let closed = windows.filter(\.workspaceIDs.isEmpty).map(\.id)
        for id in closed { remove(id) }
        return closed
    }
}

extension Array where Element == String {
    /// `self` plus `adding`, placed by `rank` (unranked entries keep their spot).
    func merged(adding: [String], rank: [String: Int]) -> [String] {
        (self + adding).enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element], rank[rhs.element]) {
            case let (l?, r?): l < r
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
