/// One observation per model of a list (perf-speed-of-light.md I1, I2): a change of one model's
/// field re-runs that model's item only, and `changed` runs only when an item differs from the one
/// handed out. The owner observes the list (which models, in what order) without reading their
/// fields, so a model change that draws the same (a split's confirm) applies nothing.
@MainActor public final class ObservedItems<Model: AnyObject & Sendable, Item: Equatable & Sendable> {
    private struct Watch {
        weak var model: Model?
        var item: Item
        let task: Task<Void, Never>
    }
    private var watches: [String: Watch] = [:]
    private let item: @MainActor @Sendable (Model) -> Item?
    private let changed: @MainActor () -> Void

    /// `item` maps one model (nil: its owner is gone); `changed` runs after an item changed.
    public init(item: @escaping @MainActor @Sendable (Model) -> Item?, changed: @escaping @MainActor () -> Void) {
        self.item = item
        self.changed = changed
    }

    /// The items of `models`, in order. A model seen first (or a new object under its id) starts
    /// its observation here; ids no longer listed stop theirs. `refresh` maps every item again
    /// (for a change no observation sees). Call it outside any observation tracking.
    public func items(for models: [Model], id: (Model) -> String, refresh: Bool = false) -> [Item] {
        var listed = Set<String>()
        let items = models.compactMap { model -> Item? in
            let key = id(model)
            listed.insert(key)
            guard var watch = watches[key], watch.model === model else { return start(model, key: key) }
            if refresh, let fresh = item(model) {
                watch.item = fresh
                watches[key] = watch
            }
            return watch.item
        }
        for key in watches.keys.filter({ !listed.contains($0) }) { watches.removeValue(forKey: key)?.task.cancel() }
        return items
    }

    public func cancelAll() {
        for watch in watches.values { watch.task.cancel() }
        watches = [:]
    }

    private func start(_ model: Model, key: String) -> Item? {
        watches.removeValue(forKey: key)?.task.cancel()
        let item = item
        // A trigger, compared with the item handed out (not the one emitted last): `refresh` moves it.
        let (first, later) = ObservationStream.current({ [weak model] in ObservationTrigger(model.flatMap(item)) })
        guard let value = first.value else { return nil }
        let task = Task { [weak self] in
            for await next in later {
                guard let self, let value = next.value else { return }
                guard var watch = self.watches[key], watch.item != value else { continue }
                watch.item = value
                self.watches[key] = watch
                self.changed()
            }
        }
        watches[key] = Watch(model: model, item: value, task: task)
        return value
    }
}
