/// A list of models, each mapped to an item, whose items in list order decide when `changed` runs: a New Tab
/// page's places (the open workspaces and tabs it lists, NewTabPlacesFeed). `list` returns nil while nobody needs
/// the items (no New Tab page open); then nothing past the list is read. The first items after nil are the
/// baseline (the consumer read them itself); `changed` runs when later items differ from the last ones.
@MainActor public final class ObservedItemsFeed<Model: AnyObject & Sendable, Item: Sendable & Equatable> {
    private let list: @MainActor @Sendable () -> [Model]?
    private let id: @MainActor (Model) -> String
    private let item: @MainActor @Sendable (Model) -> Item?
    private let changed: @MainActor () -> Void
    private let site: (fileID: StaticString, line: UInt)
    private var task: Task<Void, Never>?

    // A main-actor generic class needs a nonisolated deinit while the package targets macOS 14 (as
    // ObservedItems: the implicit isolated deinit crashes the Release inliner). This one touches nothing.
    nonisolated deinit {}

    /// - Parameters:
    ///   - list: The models in order; nil while the items are not needed.
    ///   - id: A model's stable id.
    ///   - item: One model's item (nil: the model is gone).
    ///   - changed: Runs after the items changed from the last ones.
    public init(list: @escaping @MainActor @Sendable () -> [Model]?, id: @escaping @MainActor (Model) -> String,
                item: @escaping @MainActor @Sendable (Model) -> Item?, changed: @escaping @MainActor () -> Void,
                fileID: StaticString = #fileID, line: UInt = #line) {
        self.list = list
        self.id = id
        self.item = item
        self.changed = changed
        site = (fileID, line)
    }

    /// Starts following the list (once). The feed lives until ``stop()``: an app-lifetime feed needs no
    /// other owner.
    public func start() {
        guard task == nil else { return }
        let list = list, item = item
        task = Task { [self, site] in
            var last: [Item]?
            for await trigger in ObservationStream({ ObservationTrigger(list().map { $0.compactMap(item) }) },
                                                   fileID: site.fileID, line: site.line) {
                guard let items = trigger.value else {
                    last = nil
                    continue
                }
                let before = last
                last = items
                if let before, before != items { changed() }
            }
        }
    }

    /// Stops following the list.
    public func stop() {
        task?.cancel()
        task = nil
    }
}
