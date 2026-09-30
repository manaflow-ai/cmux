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
/// without a workspace. Closing a window never ends terminals: its
/// workspaces move to the most recent other open window, or, when it is the
/// only open one, it stays registered (closed, still owning them) so
/// relaunch or reopen restores it.
///
/// Pure value type: every transition is a mutating method returning the
/// `Changes` the App animates. `WindowManager` applies them to controllers.
struct WindowRegistry: Equatable, Sendable {
    struct Window: Equatable, Sendable, Identifiable {
        let id: String
        /// Owned workspace ids (`WorkspaceModel.id`), in daemon sidebar
        /// order after `reconcile`. Never empty for a registered window.
        /// The daemon owns the order; this mirrors it.
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
        for window in windows where window.workspaceIDs.isEmpty {
            problems.append("\(window.id) has no workspaces")
        }
        return problems
    }

    // MARK: Lifecycle

    /// Registers a new open window owning `workspaceIDs` (taken from their
    /// current owners) and makes it the most recent. With no workspaces
    /// nothing is registered: a window without one does not exist.
    @discardableResult
    mutating func openWindow(id: String, workspaceIDs: [String] = [], frame: CGRect? = nil, display: String? = nil) -> Changes {
        guard window(id) == nil else { return move(workspaceIDs, to: id) }
        guard !workspaceIDs.isEmpty else { return Changes() }
        var changes = Changes()
        let taken = detach(workspaceIDs)
        windows.append(Window(id: id, workspaceIDs: taken, frame: frame, display: display))
        recency.insert(id, at: 0)
        changes.moved[id] = taken
        changes.emptied = closeEmptied()
        return changes
    }

    /// The user closed `id`. Its workspaces move to the most recent other
    /// open window; the only open window is kept, closed, with its
    /// workspaces (it owns at least one, so it is never an empty record).
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
    /// one, else `fallbackWindow`. Windows left empty close.
    @discardableResult
    mutating func reconcile(live: [String], dead: Set<String>, placements: [String: String] = [:],
                            fallbackWindow: @autoclosure () -> String) -> Changes {
        var changes = Changes()
        let rank = Dictionary(live.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for index in windows.indices {
            windows[index].workspaceIDs = windows[index].workspaceIDs.filter { !dead.contains($0) }.merged(adding: [], rank: rank)
        }
        let owned = Set(windows.flatMap(\.workspaceIDs))
        for orphan in live where !owned.contains(orphan) {
            let claimed = placements[orphan].flatMap { placementWindow($0) }
            let heir = claimed ?? mostRecentOpen() ?? recency.first ?? register(fallbackWindow())
            guard let index = windows.firstIndex(where: { $0.id == heir }) else { continue }
            windows[index].workspaceIDs = windows[index].workspaceIDs.merged(adding: [orphan], rank: rank)
            changes.moved[heir, default: []].append(orphan)
        }
        changes.emptied = closeEmptied()
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

    /// The window a claimed orphan goes to: its window when open, or a new
    /// open window with that id when none is registered. A claim on a
    /// closed window falls through to the usual heir.
    private mutating func placementWindow(_ id: String) -> String? {
        guard let existing = window(id) else { return register(id) }
        return existing.isOpen ? id : nil
    }

    /// Registers open window `id`, most recent. Its caller gives it a
    /// workspace in the same transition; `closeEmptied` removes it otherwise.
    private mutating func register(_ id: String) -> String {
        windows.append(Window(id: id))
        recency.insert(id, at: 0)
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
