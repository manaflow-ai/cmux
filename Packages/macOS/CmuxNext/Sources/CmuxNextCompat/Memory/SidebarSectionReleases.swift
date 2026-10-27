/// One owner's sections on the app's sidebar section planner, by mode (the right sidebar's sections, the docked
/// Home's two views): a ``SidebarSectionRelease`` per made view and the record each released one keeps until its
/// next show. The owner reports each show and makes, restores and removes its views; with no planner nothing goes.
@MainActor
public final class SidebarSectionReleases<Mode: Hashable & Sendable, Record: Sendable> {
    private let owner: String
    private let planner: (any SidebarSectionPlanner)?
    private let save: @MainActor (Mode) async -> Record?
    private let drop: @MainActor (Mode) -> Void
    private let holdsUnsavedInput: @MainActor (Mode) -> Bool
    private var releases: [Mode: SidebarSectionRelease] = [:]
    private var records: [Mode: Record] = [:]
    /// Each mode's shows so far: a save begun before the last show is stale when it ends.
    private var shows: [Mode: Int] = [:]

    /// - Parameters:
    ///   - owner: What the sections are (`rightSidebar`), the start of each release's key.
    ///   - planner: The app's sidebar section planner; nil keeps every view for good.
    ///   - save: A hidden mode's view-state record, before its view goes; nil keeps none.
    ///   - drop: Lets a hidden mode's view go.
    ///   - holdsUnsavedInput: A mode's view holds input its record does not keep: it stays at any pressure.
    public init(owner: String, planner: (any SidebarSectionPlanner)?, save: @escaping @MainActor (Mode) async -> Record?,
                drop: @escaping @MainActor (Mode) -> Void, holdsUnsavedInput: @escaping @MainActor (Mode) -> Bool = { _ in false }) {
        self.owner = owner
        self.planner = planner
        self.save = save
        self.drop = drop
        self.holdsUnsavedInput = holdsUnsavedInput
    }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    /// `mode` shows and each of `others` is hidden; `isNew`: its view was just made (again). A mode whose view is
    /// still made shows what it shows now, so a record an earlier save left for it is stale and goes.
    public func show(_ mode: Mode, hiding others: some Sequence<Mode>, isNew: Bool) {
        for other in others where other != mode { releases[other]?.didHide() }
        shows[mode, default: 0] += 1
        if !isNew { records[mode] = nil }
        release(of: mode)?.didShow()
        if isNew { releases[mode]?.didMake() }
    }

    /// `mode`'s view stopped showing with nothing shown in its place (its panel collapsed).
    public func hide(_ mode: Mode) { releases[mode]?.didHide() }

    /// The record `mode` was let go with, once: the view made again shows it.
    public func takeRecord(_ mode: Mode) -> Record? { records.removeValue(forKey: mode) }

    /// The owner went: the planner forgets each section.
    public func cancel() {
        for release in releases.values { release.cancel() }
    }

    private func release(of mode: Mode) -> SidebarSectionRelease? {
        if let release = releases[mode] { return release }
        guard let planner else { return nil }
        let release = SidebarSectionRelease(owner: "\(owner).\(mode)", planner: planner) { [weak self] in
            await self?.store(mode)
        } drop: { [weak self] in
            self?.drop(mode)
        } holdsUnsavedInput: { [weak self] in
            self?.holdsUnsavedInput(mode) ?? false
        }
        releases[mode] = release
        return release
    }

    /// Saves hidden `mode`'s record, an empty one too, so a release never goes with an older save's. A save that
    /// ends after the view showed (since it began) or went keeps nothing: the next release saves again first.
    private func store(_ mode: Mode) async {
        let began = shows[mode, default: 0]
        let record = await save(mode)
        guard shows[mode, default: 0] == began, let release = releases[mode], release.isHolding, !release.isShown else { return }
        records[mode] = record
    }
}
