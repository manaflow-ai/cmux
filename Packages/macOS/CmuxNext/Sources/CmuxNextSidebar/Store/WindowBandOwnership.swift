/// Which window each sidebar document item belongs to (#26632): every new window and every new Space starts clean,
/// and pins stay per window. The document (pins, Pinned and custom groups, links, saved groups) is one per home
/// session; a window lists only the items it owns (`SidebarDocProjection.windowItems`) and the workspaces it lists.
/// An item no registered window owns yet goes to the window that lists one of its workspaces, else to the front
/// window, the one it was made in (`WindowManager.adoptBands`); a new window owns nothing. Saved in each window's record
/// (`WindowRecord.bandItems`); the stored document is never changed. Pure value type, written by `WindowManager` only.
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

    /// Item ids by owning window.
    private(set) var byWindow: [String: Set<String>] = [:]
    /// Owning window by item id (derived from `byWindow`).
    private var owners: [String: String] = [:]

    public init() {}

    /// The ownership saved per window (window id, its record's `band_items`); a record from a build before #26632
    /// has none and owns nothing (its items are adopted).
    public init(saved: [(window: String, items: [String]?)]) {
        for (window, items) in saved { for item in items ?? [] { assign(item, to: window) } }
    }

    public func owner(of item: String) -> String? { owners[item] }

    /// The items window `id` owns, sorted (its record's `band_items`).
    public func items(of id: String) -> [String] { (byWindow[id] ?? []).sorted() }

    /// The items another window owns: window `id` leaves them out.
    public func hidden(in id: String) -> Set<String> {
        var hidden = Set<String>()
        for (window, items) in byWindow where window != id { hidden.formUnion(items) }
        return hidden
    }

    /// Gives `item` to `window` (nil: no window takes it).
    public mutating func assign(_ item: String, to window: String?) {
        if let old = owners[item] { byWindow[old]?.remove(item) }
        owners[item] = window
        if let window { byWindow[window, default: []].insert(item) }
    }

    /// One pass over the document's `items`: each keeps its owner while that window is registered; a workspace item
    /// follows the window that lists its workspace (`liveOwner`); any other unowned item goes to the window that lists
    /// one of its workspaces, else to `front`. Items the document no longer holds and windows no longer registered are
    /// dropped. Returns whether anything changed.
    @discardableResult
    public mutating func adopt(_ items: [SidebarDocProjection.WindowItem], registered: Set<String>, front: String?,
                        liveOwner: (SidebarDocProjection.WindowItem) -> String?) -> Bool {
        let before = self
        let ids = Set(items.map(\.id))
        for item in owners.keys where !ids.contains(item) { assign(item, to: nil) }
        for window in byWindow.keys where !registered.contains(window) {
            for item in byWindow[window] ?? [] { owners[item] = nil }
            byWindow[window] = nil
        }
        for item in items {
            let live = liveOwner(item).flatMap { registered.contains($0) ? $0 : nil }
            if item.ref?.kind == LayoutItemRef.workspaceKind, let live {
                if owners[item.id] != live { assign(item.id, to: live) }
            } else if owners[item.id] == nil {
                assign(item.id, to: live ?? front)
            }
        }
        byWindow = byWindow.filter { !$0.value.isEmpty }
        return self != before
    }

    public static func == (lhs: WindowBandOwnership, rhs: WindowBandOwnership) -> Bool { lhs.byWindow == rhs.byWindow }
}
