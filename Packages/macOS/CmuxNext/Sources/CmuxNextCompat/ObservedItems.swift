/// One observation per model of a list (perf-speed-of-light.md I1, I2): a change of one model's
/// field re-runs that model's item only, and `changed` runs only when an item differs from the one
/// handed out. The owner observes the list (which models, in what order) without reading their
/// fields, so a model change that draws the same (a split's confirm) applies nothing.
///
/// The work after one model's change must not grow with the list (PATTERNS.md, targeted observation). An owner
/// that joins the items of a session-sized list takes ``init(item:same:changedItem:fileID:line:)``: it gets the
/// ONE changed item (``Change``: its place in the items handed out last, the item before and the item now) and
/// updates its join from it. ``items(for:id:refresh:)`` visits every listed model, so it is for a change of the
/// list (and the first read), never for one item's change.
@MainActor public final class ObservedItems<Model: AnyObject & Sendable, Item: Sendable> {
    /// One item's change: its place in the items ``items(for:id:refresh:)`` handed out last, the item handed out
    /// before and the item now. The place is right only while each listed model has its own id, as the workspaces
    /// of a store do: of two listed models under one id, the later one replaces the observation of the earlier one.
    public struct Change: Sendable {
        public let position: Int
        public let old: Item
        public let new: Item
    }

    private struct Watch {
        weak var model: Model?
        var item: Item
        let task: Task<Void, Never>
        /// The item's index in the items handed out last.
        var position: Int
    }
    private var watches: [String: Watch] = [:]
    private let item: @MainActor @Sendable (Model) -> Item?
    private let same: (Item, Item) -> Bool
    private let changed: (Change) -> Void
    /// The owner's `#fileID:#line`, for the streams it starts (``ObservationWakes`` names its wakes by it).
    private let site: (fileID: StaticString, line: UInt)

    // A main-actor generic class needs a nonisolated deinit while the package targets macOS 14: the
    // implicit isolated deinit crashes swift-frontend 6.3.3's Release inliner (EarlyPerfInliner,
    // isCallerAndCalleeLayoutConstraintsCompatible) on its deallocating deinit. This one touches nothing.
    nonisolated deinit {}

    /// `item` maps one model (nil: its owner is gone); `changed` runs after an item changed
    /// (`same` false: an item's equality may be main-actor isolated, so it is passed in). For an owner whose
    /// list does not grow with the session (one strip's tabs): it reads ``items(for:id:refresh:)`` again after a
    /// change. An owner that joins the items of every workspace takes ``init(item:same:changedItem:fileID:line:)``.
    /// Two owners of a session-sized list still take this one and so still pass over their list after one
    /// change (2026-11-10): `SidebarSessionTreeFeed` and `AgentPaneLinkPlaces`, and `ObservedItemsFeed` does it
    /// for its callers. Do not add one.
    public convenience init(item: @escaping @MainActor @Sendable (Model) -> Item?, same: @escaping (Item, Item) -> Bool,
                            changed: @escaping () -> Void, fileID: StaticString = #fileID, line: UInt = #line) {
        self.init(item: item, same: same, changedItem: { _ in changed() }, fileID: fileID, line: line)
    }

    /// `item` maps one model (nil: its owner is gone); `changedItem` runs after an item changed (`same` false)
    /// with that one change: the owner updates what it joined from it, with no pass over the list.
    public init(item: @escaping @MainActor @Sendable (Model) -> Item?, same: @escaping (Item, Item) -> Bool,
                changedItem: @escaping (Change) -> Void, fileID: StaticString = #fileID, line: UInt = #line) {
        site = (fileID, line)
        self.item = item
        self.same = same
        changed = changedItem
    }

    /// The items of `models`, in order. A model seen first (or a new object under its id) starts
    /// its observation here; ids no longer listed stop theirs. `refresh` maps every item again
    /// (for a change no observation sees). Call it outside any observation tracking. It visits every listed
    /// model: call it when the list changed, never after one item's change (``Change`` has that item).
    public func items(for models: [Model], id: (Model) -> String, refresh: Bool = false) -> [Item] {
        // Every listed model is visited (``ObservationWork`` counts them for a test).
        ObservationWork.visited(models.count, "ObservedItems.list")
        var listed = Set<String>()
        // The index of the next item handed out (a model with no item has none).
        var position = 0
        let items = models.compactMap { model -> Item? in
            let key = id(model)
            listed.insert(key)
            guard var watch = watches[key], watch.model === model else {
                guard let first = start(model, key: key, position: position) else { return nil }
                position += 1
                return first
            }
            let fresh = refresh ? item(model) : nil
            if fresh != nil || watch.position != position {
                if let fresh { watch.item = fresh }
                watch.position = position
                watches[key] = watch
            }
            position += 1
            return watch.item
        }
        for key in watches.keys.filter({ !listed.contains($0) }) { watches.removeValue(forKey: key)?.task.cancel() }
        return items
    }

    public func cancelAll() {
        for watch in watches.values { watch.task.cancel() }
        watches = [:]
    }

    private func start(_ model: Model, key: String, position: Int) -> Item? {
        watches.removeValue(forKey: key)?.task.cancel()
        let map = self.item
        // Each map of a model is counted (``ObservationWork``): one model's change maps that model only.
        let counted: @MainActor @Sendable (Model) -> Item? = { model in
            ObservationWork.visited(1, "ObservedItems.map")
            return map(model)
        }
        // A trigger, compared with the item handed out (not the one emitted last): `refresh` moves it.
        let (first, later) = ObservationStream.current({ [weak model] in ObservationTrigger(model.flatMap(counted)) },
                                                       fileID: site.fileID, line: site.line)
        guard let value = first.value else { return nil }
        let task = Task { [weak self] in
            for await next in later {
                guard let self, let value = next.value else { return }
                guard var watch = self.watches[key], !self.same(watch.item, value) else { continue }
                let old = watch.item
                watch.item = value
                self.watches[key] = watch
                self.changed(Change(position: watch.position, old: old, new: value))
            }
        }
        watches[key] = Watch(model: model, item: value, task: task, position: position)
        return value
    }
}
