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
/// (``ObservedItems``). A list change maps only the models new to it; a model's change re-maps that model only and
/// puts its item in its place in the items, with no pass over the list.
@MainActor public final class ObservedItemsFeed<Model: AnyObject & Sendable, Item: Sendable & Equatable> {
    /// What the feed's items became, for an owner that keeps them in step: every item after a pass over the list
    /// (the baseline, or a change of the list), or the one item that changed.
    public enum Update: Sendable {
        /// The items in list order, after a pass over the list.
        case items([Item])
        /// One item's change: its place in the items given last, the item before and the item now.
        case item(ObservedItems<Model, Item>.Change)
    }

    private let list: @MainActor @Sendable () -> [Model]?
    private let id: @MainActor (Model) -> String
    private let item: @MainActor @Sendable (Model) -> Item?
    private let changed: @MainActor () -> Void
    private let update: (@MainActor (Update) -> Void)?
    private let site: (fileID: StaticString, line: UInt)
    private var task: Task<Void, Never>?
    private var observed: ObservedItems<Model, Item>?
    /// The models listed last; nil while there is no list.
    private var models: [Model]?
    /// The items handed out last; nil until the baseline after a list. Each change of them moves `revision`.
    private var last: [Item]?
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
    ///   - item: One model's item (nil: the model is gone). A listed model whose item is nil has no observation:
    ///     it is mapped again at the next pass over the list (a change of the list), not at the change of the
    ///     item of another model.
    ///   - changed: Runs after the items changed from the last ones (not for the baseline).
    ///   - update: Runs at once after the items changed, the baseline included and before `changed`, with what
    ///     they became: an owner that keeps the items sets its one item at one item's change. It does not run
    ///     when the list ends.
    public init(list: @escaping @MainActor @Sendable () -> [Model]?, id: @escaping @MainActor (Model) -> String,
                item: @escaping @MainActor @Sendable (Model) -> Item?, changed: @escaping @MainActor () -> Void = {},
                update: (@MainActor (Update) -> Void)? = nil, fileID: StaticString = #fileID, line: UInt = #line) {
        self.list = list
        self.id = id
        self.item = item
        self.changed = changed
        self.update = update
        site = (fileID, line)
    }

    /// Starts following the list (once). The feed lives until ``stop()``: an app-lifetime feed needs no
    /// other owner.
    public func start() {
        guard task == nil else { return }
        let list = list
        observed = ObservedItems(item: item, same: { $0 == $1 }, changedItem: { [weak self] change in self?.itemChanged(change) },
                                 fileID: site.fileID, line: site.line)
        task = Task { [self, site] in
            for await trigger in ObservationStream({ ObservationTrigger(list()) }, fileID: site.fileID, line: site.line) {
                guard let listed = trigger.value else {
                    observed?.cancelAll()
                    clear()
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
        clear()
    }

    /// The list ended: there are no models and no items, and a tracked reader of the items hears it.
    private func clear() {
        models = nil
        guard last != nil else { return }
        last = nil
        revision.move()
    }

    /// A pass over the list, for the first read and a change of the list: compares the items now with the last
    /// ones; only new models are mapped (``ObservedItems`` keeps the rest).
    private func settle() {
        guard let observed, let models else { return }
        let items = observed.items(for: models, id: id)
        let before = last
        guard before != items else { return }
        last = items
        revision.move()
        update?(.items(items))
        if before != nil { changed() }
    }

    /// One item changed: it goes in its place in the last items, with no pass over the list. The place is the
    /// item's own while each id of the list has one place and the place holds the item given before; if not,
    /// the feed passes over its list as for a change of the list, so no item is written to a place of another.
    private func itemChanged(_ change: ObservedItems<Model, Item>.Change) {
        guard let observed, observed.listsEachIDOnce, last?.indices.contains(change.position) == true,
              last?[change.position] == change.old else {
            settle()
            return
        }
        last?[change.position] = change.new
        revision.move()
        update?(.item(change))
        changed()
    }
}

/// Moves when a feed's items change: the one cell a tracked reader of ``ObservedItemsFeed/observedItems`` registers on.
@Observable @MainActor final class ObservedItemsRevision {
    private(set) var value: UInt64 = 0

    func move() { value &+= 1 }
}
