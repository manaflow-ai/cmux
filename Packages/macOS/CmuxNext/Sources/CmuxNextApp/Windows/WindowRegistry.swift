import CoreGraphics
import Foundation

/// App-wide window membership and lifecycle (plans/cmux-next/REWRITE.md
/// "Tab drag", user feedback 2026-09-29): which workspaces each window's
/// sidebar shows, and which windows exist. Everything else a window has
/// (selected workspace, sidebar width, focus, screen switcher) is that
/// window's own `WindowState`.
///
/// Invariant: every workspace is owned by at most one window, and every
/// live workspace by exactly one after `reconcile`. A window that loses its
/// last workspace closes, unless it is the only open window: that one stays
/// and shows an empty state. Closing a window never ends terminals: its
/// workspaces move to the most recent other open window, or, when it is the
/// only one, it stays registered (closed) so relaunch or reopen restores it.
///
/// Pure value type: every transition is a mutating method returning the
/// `Changes` the App animates. `WindowManager` applies them to controllers.
struct WindowRegistry: Equatable, Sendable {
    struct Window: Equatable, Sendable, Identifiable {
        let id: String
        /// Owned workspace ids (`WorkspaceModel.id`), in daemon sidebar
        /// order after `reconcile`. The daemon owns the order; this mirrors it.
        var workspaceIDs: [String]
        /// AppKit screen frame (bottom-left origin).
        var frame: CGRect?
        /// Display the window was on (`CGDisplayCreateUUIDFromDisplayID`).
        var display: String?
        /// False for the last window after the user closed it: kept so its
        /// workspaces stay restorable.
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

        var isEmpty: Bool { emptied.isEmpty && moved.isEmpty }
    }

    /// Creation order.
    private(set) var windows: [Window] = []
    /// Window ids, most recently active first.
    private(set) var recency: [String] = []

    init(windows: [Window] = []) {
        self.windows = windows
        recency = windows.map(\.id)
    }

    // MARK: Queries

    func window(_ id: String) -> Window? { windows.first { $0.id == id } }

    func owner(of workspaceID: String) -> String? {
        windows.first { $0.workspaceIDs.contains(workspaceID) }?.id
    }

    var openWindows: [Window] { windows.filter(\.isOpen) }

    /// The most recently active open window, excluding `excluded`.
    func mostRecentOpen(excluding excluded: Set<String> = []) -> String? {
        let open = Set(openWindows.map(\.id)).subtracting(excluded)
        return recency.first { open.contains($0) } ?? windows.first { open.contains($0.id) }?.id
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
        let open = openWindows
        for window in open where window.workspaceIDs.isEmpty && open.count > 1 {
            problems.append("\(window.id) is empty but not the only open window")
        }
        return problems
    }

    // MARK: Lifecycle

    /// Registers a new open window owning `workspaceIDs` (taken from their
    /// current owners) and makes it the most recent.
    @discardableResult
    mutating func openWindow(id: String, workspaceIDs: [String] = [], frame: CGRect? = nil, display: String? = nil) -> Changes {
        guard window(id) == nil else { return move(workspaceIDs, to: id) }
        var changes = Changes()
        let taken = detach(workspaceIDs)
        windows.append(Window(id: id, workspaceIDs: taken, frame: frame, display: display))
        recency.insert(id, at: 0)
        if !taken.isEmpty { changes.moved[id] = taken }
        changes.emptied = closeEmptied(keeping: id)
        return changes
    }

    /// The user closed `id`. Its workspaces move to the most recent other
    /// open window; the only open window is kept, closed, with its workspaces.
    @discardableResult
    mutating func close(_ id: String) -> Changes {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return Changes() }
        guard let heir = mostRecentOpen(excluding: [id]) else {
            windows[index].isOpen = false
            return Changes()
        }
        var changes = Changes()
        let orphans = windows[index].workspaceIDs
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
        guard let id = recency.first(where: { id in window(id)?.isOpen == false }),
              let index = windows.firstIndex(where: { $0.id == id }) else { return nil }
        windows[index].isOpen = true
        activate(id)
        return id
    }

    mutating func activate(_ id: String) {
        guard window(id) != nil else { return }
        recency.removeAll { $0 == id }
        recency.insert(id, at: 0)
    }

    mutating func setGeometry(_ id: String, frame: CGRect?, display: String?) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].frame = frame
        if let display { windows[index].display = display }
    }

    // MARK: Membership

    /// Moves `workspaceIDs` into window `id`, before `anchor` when it is
    /// already there (else appended). Windows left empty close.
    @discardableResult
    mutating func move(_ workspaceIDs: [String], to id: String, before anchor: String? = nil) -> Changes {
        guard window(id) != nil, !workspaceIDs.isEmpty else { return Changes() }
        var changes = Changes()
        let taken = detach(workspaceIDs)
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return changes }
        let slot = anchor.flatMap { windows[index].workspaceIDs.firstIndex(of: $0) } ?? windows[index].workspaceIDs.endIndex
        windows[index].workspaceIDs.insert(contentsOf: taken, at: slot)
        changes.moved[id] = taken
        changes.emptied = closeEmptied(keeping: id)
        return changes
    }

    /// Brings membership in line with the daemons: drops `dead` workspaces
    /// (known gone; a workspace whose machine is still connecting is not
    /// dead, so its window survives relaunch), orders each window like
    /// `live`, and gives orphans (created by a drag, the CLI, another
    /// device) to their `placements` window when it is open, else the most
    /// recent open window, else `fallbackWindow` when none is registered.
    @discardableResult
    mutating func reconcile(live: [String], dead: Set<String>, placements: [String: String] = [:],
                            fallbackWindow: @autoclosure () -> String) -> Changes {
        var changes = Changes()
        let rank = Dictionary(live.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for index in windows.indices {
            windows[index].workspaceIDs = windows[index].workspaceIDs.filter { !dead.contains($0) }.merged(adding: [], rank: rank)
        }
        let owned = Set(windows.flatMap(\.workspaceIDs))
        let open = Set(openWindows.map(\.id))
        for orphan in live where !owned.contains(orphan) {
            let heir = placements[orphan].flatMap { open.contains($0) ? $0 : nil } ?? mostRecentOpen() ?? recency.first ?? {
                let id = fallbackWindow()
                windows.append(Window(id: id))
                recency.insert(id, at: 0)
                return id
            }()
            guard let index = windows.firstIndex(where: { $0.id == heir }) else { continue }
            windows[index].workspaceIDs = windows[index].workspaceIDs.merged(adding: [orphan], rank: rank)
            changes.moved[heir, default: []].append(orphan)
        }
        changes.emptied = closeEmptied(keeping: nil)
        return changes
    }

    /// Orders each window's workspaces like `live` (the daemons' order);
    /// workspaces not in it keep their place after the ordered ones.
    mutating func order(like live: [String]) {
        let rank = Dictionary(live.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for index in windows.indices { windows[index].workspaceIDs = windows[index].workspaceIDs.merged(adding: [], rank: rank) }
    }

    // MARK: Internals

    /// Removes `ids` from every window; returns them in the given order,
    /// without duplicates.
    private mutating func detach(_ ids: [String]) -> [String] {
        var unique: [String] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        let set = Set(unique)
        for index in windows.indices { windows[index].workspaceIDs.removeAll { set.contains($0) } }
        return unique
    }

    private mutating func remove(_ id: String) {
        windows.removeAll { $0.id == id }
        recency.removeAll { $0 == id }
    }

    /// Removes windows with no workspaces, except one open window when no
    /// non-empty open window remains: `preferred` if it is such a window,
    /// else the most recent one.
    private mutating func closeEmptied(keeping preferred: String?) -> [String] {
        let empty = windows.filter(\.workspaceIDs.isEmpty)
        guard !empty.isEmpty else { return [] }
        var survivor: String?
        if !openWindows.contains(where: { !$0.workspaceIDs.isEmpty }) {
            let candidates = Set(empty.filter(\.isOpen).map(\.id))
            survivor = preferred.flatMap { candidates.contains($0) ? $0 : nil } ?? recency.first { candidates.contains($0) }
        }
        let closed = empty.map(\.id).filter { $0 != survivor }
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
