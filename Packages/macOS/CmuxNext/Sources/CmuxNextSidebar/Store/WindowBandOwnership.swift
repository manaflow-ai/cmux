/// Which window each sidebar document item belongs to (#26632): every new window, also one opened on another macOS
/// Space, starts clean, and pins stay per window. The document (pins, Pinned and custom groups, links, saved groups)
/// is one per home session; a window lists only the items it owns (`SidebarDocProjection.windowItems`) and the
/// workspaces it lists. An item no window owns yet goes to the window it was made in (the acting window of the
/// change), else to the window that lists one of its workspaces, else to the front window (`WindowManager.adoptBands`);
/// a new window owns nothing. Saved in each window's record (`WindowRecord.bandItems`); the stored document is never
/// changed. Pure value type, written by `WindowManager` only.
public nonisolated struct WindowBandOwnership: Equatable, Sendable {
    /// What one ownership pass reads: the document's window items and each window's workspaces (not the window
    /// order, so a key change runs no pass).
    public nonisolated struct Inputs: Equatable, Sendable {
        public var items: [SidebarDocProjection.WindowItem]
        public var windows: [String: [String]]

        public init(items: [SidebarDocProjection.WindowItem], windows: [String: [String]]) {
            self.items = items
            self.windows = windows
        }
    }

    /// Item ids by owning window. An item the document no longer lists keeps its owner (an undo, or a move out of
    /// a group, brings it back to the same window); only the items it lists are saved.
    private(set) var byWindow: [String: Set<String>] = [:]
    /// Owning window by item id (derived from `byWindow`).
    private var owners: [String: String] = [:]
    /// The items the document listed at the last pass; nil before the first one.
    private var present: Set<String>?
    /// Incognito windows seen by a pass: when one goes, its items stay with it, hidden everywhere (never handed to
    /// a normal window).
    private var incognito: Set<String> = []

    public init() {}

    /// The ownership saved per window (window id, its record's `band_items`); a record from a build before #26632
    /// has none and owns nothing (its items are adopted).
    public init(saved: [(window: String, items: [String]?)]) {
        for (window, items) in saved { for item in items ?? [] { assign(item, to: window) } }
    }

    public func owner(of item: String) -> String? { owners[item] }

    /// The items window `id` owns that the document lists, sorted (its record's `band_items`).
    public func items(of id: String) -> [String] {
        let owned = byWindow[id] ?? []
        return (present.map { owned.intersection($0) } ?? owned).sorted()
    }

    /// The items another window owns: window `id` leaves them out.
    public func hidden(in id: String) -> Set<String> {
        var hidden = Set<String>()
        for (window, items) in byWindow where window != id { hidden.formUnion(items) }
        return hidden
    }

    /// Gives `item` to `window` (nil: no window takes it).
    public mutating func assign(_ item: String, to window: String?) {
        if let old = owners[item] {
            byWindow[old]?.remove(item)
            if byWindow[old]?.isEmpty == true { byWindow[old] = nil }
        }
        owners[item] = window
        if let window { byWindow[window, default: []].insert(item) }
    }

    /// One pass over the document's `items`. Each item keeps its owner; a workspace item follows the window that
    /// lists its workspace (`liveOwner`). An unowned item new since the last pass goes to `acting` (the window the
    /// local change that added it was made in); any other unowned one to the window that lists one of its
    /// workspaces, else to `front`. The items of a normal window that is no longer registered go to `front` (kept
    /// while no normal window is open); an incognito window's stay hidden. Returns whether anything changed.
    @discardableResult
    public mutating func adopt(_ items: [SidebarDocProjection.WindowItem], registered: Set<String>, incognito windows: Set<String> = [],
                               acting: String? = nil, front: String?,
                               liveOwner: (SidebarDocProjection.WindowItem) -> String?) -> Bool {
        let before = self
        incognito.formUnion(windows)
        if let front {
            for window in Array(byWindow.keys) where !registered.contains(window) && !incognito.contains(window) {
                for item in byWindow[window] ?? [] { assign(item, to: front) }
            }
        }
        let acting = acting.flatMap { registered.contains($0) ? $0 : nil }
        let known = present ?? Set(items.map(\.id)) // the first pass adopts what was there: no item is new
        for item in items {
            let isWorkspace = item.ref?.kind == LayoutItemRef.workspaceKind
            guard isWorkspace || owners[item.id] == nil else { continue }
            let live = liveOwner(item).flatMap { registered.contains($0) ? $0 : nil }
            if isWorkspace, let live {
                if owners[item.id] != live { assign(item.id, to: live) }
            } else if owners[item.id] == nil {
                assign(item.id, to: (known.contains(item.id) ? nil : acting) ?? live ?? front)
            }
        }
        present = Set(items.map(\.id))
        return byWindow != before.byWindow || present != before.present
    }

    public static func == (lhs: WindowBandOwnership, rhs: WindowBandOwnership) -> Bool {
        lhs.byWindow == rhs.byWindow && lhs.present == rhs.present
    }
}
