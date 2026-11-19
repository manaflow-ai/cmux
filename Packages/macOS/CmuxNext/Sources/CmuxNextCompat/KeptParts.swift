import Observation

/// The parts that a map makes for the models of an owner, one for each model, each kept until its own model
/// changes: a workspace's rows for the New Tab bar are joined from one part for each of its tabs, and a tab that
/// comes, goes or changes makes its own part and no other tab's.
///
/// A map that runs under one observation of the owner reads each model of the owner again at each change of one
/// of them: the work of one change grows with the owner (a workspace of 84 tabs made 85 parts for one new tab).
/// Here each part has its own observation (``SingleArmedTracking``): ``parts(of:_:make:)`` runs `make` for a model
/// that is new to the owner and for a model whose part read something that changed after, and gives the kept part
/// for each other model. A caller that runs under an observation hears the change of a kept part too: the call
/// reads one cell of the owner, which moves when a kept part of that owner changes. A caller whose own call made
/// a part read that part's values too (a part's `make` runs inside the caller's observation), so one change
/// reaches it by 2 ways: ``SingleArmedTracking`` and ``ObservationStream`` count one registration one time, and a
/// caller under a plain `withObservationTracking` can have its callback called 2 times for one change.
///
/// `make` reads only what its part needs. A part is made again only when something that `make` read changes, so a
/// value that `make` reads and that is not observable keeps its old part. Such a value is the part's input:
/// ``parts(of:_:input:make:)`` reads `input` for each model at each call, outside the part's observation, gives it
/// to `make`, and makes the part again when it is not the input that the kept part was made with. The read of an
/// input is the caller's: a caller under an observation hears what `input` read, and each call reads it for each
/// model, so an input is a small read.
///
/// The parts of a model that left the owner's list go at the next call for that owner, with their observations.
/// An owner is held weakly; the parts of an owner that is gone go when the owners doubled.
///
/// ```swift
/// let kept = KeptParts<WorkspaceModel, TabModel, Row?>(step: "Rows.tabParts")
/// let rows = kept.parts(of: workspace, workspace.tabs) { row(of: $0) }.compactMap { $0 }
/// ```
@MainActor
public final class KeptParts<Owner: AnyObject, Model: AnyObject, Part> {
    /// One model's part and its observation.
    private struct Entry {
        /// The model the part is of: an id whose model is gone, or is another object, has no part here.
        weak var model: Model?
        var part: Part
        /// The input that the part was made with (a ``Given``).
        let input: Any
        let mark: KeptPartMark
        let tracking: SingleArmedTracking
    }

    /// The input that a kept part was made with, as its own type: a part is kept only for an input of the same
    /// type that is equal.
    private struct Given<Input: Equatable> {
        let value: Input
    }

    /// The input of a part that has none (``parts(of:_:make:)``): each one equals each other one.
    private struct NoInput: Equatable {}

    /// One owner's parts, by model.
    @MainActor private final class Store {
        weak var owner: Owner?
        let signal = KeptPartSignal()
        var entries: [ObjectIdentifier: Entry] = [:]

        init(_ owner: Owner) { self.owner = owner }

        // As the outer class: a main-actor generic class needs a nonisolated deinit while the package targets macOS 14.
        nonisolated deinit {}
    }

    /// The name of the count of the parts made (``ObservationWork``).
    private let step: StaticString
    private let site: (fileID: StaticString, line: UInt)
    private var stores: [ObjectIdentifier: Store] = [:]
    /// The count of owners at which the parts of each owner that is gone are removed.
    private var sweepAt = 64

    // A main-actor generic class needs a nonisolated deinit while the package targets macOS 14 (as
    // ObservedItems: the implicit isolated deinit crashes the Release inliner). This one touches nothing.
    nonisolated deinit {}

    /// Creates an empty holder.
    /// - Parameter step: The name under which the parts made are counted for a test (``ObservationWork``).
    public init(step: StaticString, fileID: StaticString = #fileID, line: UInt = #line) {
        self.step = step
        site = (fileID, line)
    }

    /// The parts of `models`, in their order: the kept part of each model whose part read nothing that changed,
    /// and a part made now by `make` for each other model. The parts of the owner's models that are not in
    /// `models` are removed.
    /// - Parameters:
    ///   - owner: What the models belong to (a workspace).
    ///   - models: The owner's models, in order (its tabs).
    ///   - make: One model's part. It runs under the part's own observation.
    public func parts(of owner: Owner, _ models: [Model], make: (Model) -> Part) -> [Part] {
        parts(of: owner, models, input: { _ in NoInput() }, make: { model, _ in make(model) })
    }

    /// The parts of `models` as ``parts(of:_:make:)``, each with an input: what its `make` needs and can not
    /// observe. A kept part is given only while its input is the one that it was made with.
    /// - Parameters:
    ///   - owner: What the models belong to (a workspace).
    ///   - models: The owner's models, in order (its tabs).
    ///   - input: One model's input, read at each call for each model, outside the part's observation.
    ///   - make: One model's part from its input. It runs under the part's own observation.
    public func parts<Input: Equatable>(of owner: Owner, _ models: [Model], input: (Model) -> Input,
                                        make: (Model, Input) -> Part) -> [Part] {
        let store = held(for: owner)
        store.signal.observe()
        var parts: [Part] = []
        parts.reserveCapacity(models.count)
        var made = 0
        for model in models {
            let id = ObjectIdentifier(model)
            var kept = store.entries[id]
            if let entry = kept, entry.model !== model {
                // The id is of a model that is gone: its part is not this model's.
                entry.mark.drop()
                kept = nil
            }
            let now = input(model)
            if let entry = kept, !entry.mark.isStale {
                if let with = entry.input as? Given<Input>, with.value == now {
                    parts.append(entry.part)
                    continue
                }
                // Another input: the part's observation is of what the old part read, and it is still armed. It
                // ends here, and the new part gets its own, so what the new part reads is observed.
                entry.mark.drop()
                kept = nil
            }
            let mark = kept?.mark ?? KeptPartMark(store.signal)
            let tracking = kept?.tracking ?? SingleArmedTracking()
            // Before the read, so a change in the middle of `make` leaves the part stale.
            mark.fresh()
            let part = tracking.track(shape: [], { () -> Part in
                mark.observe()
                return make(model, now)
            }, onChange: { mark.fire() }, fileID: site.fileID, line: site.line)
            store.entries[id] = Entry(model: model, part: part, input: Given(value: now), mark: mark, tracking: tracking)
            made += 1
            parts.append(part)
        }
        if store.entries.count != models.count { removeParts(of: store, notIn: models) }
        ObservationWork.visited(made, step)
        return parts
    }

    /// The parts of `models` from `kept`, as ``parts(of:_:input:make:)``; with no holder each part is made now and
    /// none is kept: one map for a caller that keeps its parts (a feed) and for one that does not (a walk).
    public static func parts<Input: Equatable>(of owner: Owner, _ models: [Model], kept: KeptParts?, input: (Model) -> Input,
                                               make: (Model, Input) -> Part) -> [Part] {
        guard let kept else { return models.map { make($0, input($0)) } }
        return kept.parts(of: owner, models, input: input, make: make)
    }

    /// Removes each part of `store` whose model is not in `models`, with its observation.
    private func removeParts(of store: Store, notIn models: [Model]) {
        let listed = Set(models.map { ObjectIdentifier($0) })
        let gone = store.entries.keys.filter { !listed.contains($0) }
        for id in gone { store.entries.removeValue(forKey: id)?.mark.drop() }
    }

    /// The owner's store; a new one for an owner with none.
    private func held(for owner: Owner) -> Store {
        let id = ObjectIdentifier(owner)
        if let store = stores[id] {
            if store.owner === owner { return store }
            // The id is of an owner that is gone.
            empty(store)
        } else if stores.count >= sweepAt {
            let gone = stores.filter { $0.value.owner == nil }.map(\.key)
            for old in gone {
                if let store = stores.removeValue(forKey: old) { empty(store) }
            }
            sweepAt = max(64, stores.count * 2)
        }
        let store = Store(owner)
        stores[id] = store
        return store
    }

    /// Removes each part of `store`, with its observation.
    private func empty(_ store: Store) {
        for entry in store.entries.values { entry.mark.drop() }
        store.entries = [:]
    }
}

/// The one cell of an owner that a caller of ``KeptParts/parts(of:_:make:)`` reads: it moves when a kept part of
/// that owner changes. Sendable: a change callback is not isolated.
final class KeptPartSignal: Observable, Sendable {
    private let registrar = ObservationRegistrar()

    /// Identity of the moves for Observation (never read for its value).
    private var moves: Int { 0 }

    /// A tracked read: the reader hears the next move.
    func observe() { registrar.access(self, keyPath: \.moves) }

    func move() {
        registrar.willSet(self, keyPath: \.moves)
        registrar.didSet(self, keyPath: \.moves)
    }
}

/// One kept part's state: stale after something that its `make` read changed. Sendable: the change callback of the
/// part's observation is not isolated.
final class KeptPartMark: Observable, Sendable {
    private let registrar = ObservationRegistrar()
    private let stale = Atomic<Bool>(false)
    private let dropped = Atomic<Bool>(false)
    private let signal: KeptPartSignal

    init(_ signal: KeptPartSignal) { self.signal = signal }

    /// Identity of the drop for Observation (never read for its value).
    private var drops: Int { 0 }

    /// Something that the part's `make` read changed after the part was made.
    var isStale: Bool { stale.load(ordering: .acquiring) }

    /// The part is made now.
    func fresh() { stale.store(false, ordering: .releasing) }

    /// A tracked read inside the part's observation, so ``drop()`` ends that observation.
    func observe() { registrar.access(self, keyPath: \.drops) }

    /// The part's observation fired: the part is stale, and the owner's cell moves while the part is kept.
    func fire() {
        stale.store(true, ordering: .releasing)
        if !dropped.load(ordering: .acquiring) { signal.move() }
    }

    /// The part is removed: its observation ends here and does not stay on what `make` read. The owner's cell
    /// does not move.
    func drop() {
        dropped.store(true, ordering: .releasing)
        registrar.willSet(self, keyPath: \.drops)
        registrar.didSet(self, keyPath: \.drops)
    }
}
