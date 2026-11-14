import Observation

/// A list of models, each mapped to an item, whose items in list order decide when `changed` runs: a New Tab
/// page's places (the open workspaces and tabs it lists, NewTabPlacesFeed). `list` returns nil while nobody needs
/// the items (no New Tab page open); then nothing past the list is read. The first items after nil are the
/// baseline (the consumer read them itself); `changed` runs when later items differ from the last ones.
///
/// A consumer that lives inside Observation tracking and reads nothing itself (the keep-awake facts, the terminals
/// whose clipboard reads this Mac answers, the browser tabs the app announces) reads ``observedItems``: one
/// registration, on the feed, in place of one on every model's fields. It hears the baseline too.
///
/// The work of one change does not grow with the list (perf-speed-of-light.md I1, I2; PATTERNS.md targeted
/// observation): the list is observed without reading any model's fields, and each model has its own observation
/// (``ObservedItems``). A list change maps only the models new to it; a model's change re-maps that model only.
@MainActor public final class ObservedItemsFeed<Model: AnyObject & Sendable, Item: Sendable & Equatable> {
    private let list: @MainActor @Sendable () -> [Model]?
    private let id: @MainActor (Model) -> String
    private let item: @MainActor @Sendable (Model) -> Item?
    private let changed: @MainActor () -> Void
    private let site: (fileID: StaticString, line: UInt)
    private var task: Task<Void, Never>?
    private var observed: ObservedItems<Model, Item>?
    /// The models listed last; nil while there is no list.
    private var models: [Model]?
    /// The items handed out last; nil until the baseline after a list.
    private var last: [Item]? { didSet { if last != oldValue { revision.move() } } }
    private let revision = ObservedItemsRevision()
    /// The items in list order as of the last change (nil: no list, or the list is not mapped yet). A tracked read:
    /// the reader hears the next change of the items, the baseline and the end of the list, and nothing else.
    public var observedItems: [Item]? {
        _ = revision.value
        return last
    }

    // A main-actor generic class needs a nonisolated deinit while the package targets macOS 14 (as
    // ObservedItems: the implicit isolated deinit crashes the Release inliner). This one touches nothing.
    nonisolated deinit {}

    /// - Parameters:
    ///   - list: The models in order; nil while the items are not needed.
    ///   - id: A model's stable id.
    ///   - item: One model's item (nil: the model is gone).
    ///   - changed: Runs after the items changed from the last ones (not for the baseline).
    public init(list: @escaping @MainActor @Sendable () -> [Model]?, id: @escaping @MainActor (Model) -> String,
                item: @escaping @MainActor @Sendable (Model) -> Item?, changed: @escaping @MainActor () -> Void = {},
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
        let list = list
        observed = ObservedItems(item: item, same: { $0 == $1 }, changed: { [weak self] in self?.settle() },
                                 fileID: site.fileID, line: site.line)
        task = Task { [self, site] in
            for await trigger in ObservationStream({ ObservationTrigger(list()) }, fileID: site.fileID, line: site.line) {
                guard let listed = trigger.value else {
                    observed?.cancelAll()
                    models = nil
                    last = nil
                    continue
                }
                models = listed
                settle()
            }
        }
    }

    /// Stops following the list.
    public func stop() {
        task?.cancel()
        task = nil
        observed?.cancelAll()
        observed = nil
        models = nil
        last = nil
    }

    /// Compares the items now with the last ones; only new models are mapped (``ObservedItems`` keeps the rest).
    private func settle() {
        guard let observed, let models else { return }
        let items = observed.items(for: models, id: id)
        let before = last
        last = items
        if let before, before != items { changed() }
    }
}

/// Moves when a feed's items change: the one cell a tracked reader of ``ObservedItemsFeed/observedItems`` registers on.
@Observable @MainActor final class ObservedItemsRevision {
    private(set) var value: UInt64 = 0

    func move() { value &+= 1 }
}
