/// One owner's sections on the app's sidebar section planner, by mode (the right sidebar's sections, the docked
/// Home's two views): a ``SidebarSectionRelease`` per made view and the record each released one keeps until its
/// next show. The owner reports each show and makes, restores and removes its views; with no planner nothing goes.
@MainActor
public final class SidebarSectionReleases<Mode: Hashable & Sendable, Record: Sendable> {
    private let owner: String
    private let planner: (any SidebarSectionPlanner)?
    private let save: @MainActor (Mode) async -> Record?
    private let drop: @MainActor (Mode) -> Void
    private var releases: [Mode: SidebarSectionRelease] = [:]
    private var records: [Mode: Record] = [:]

    /// - Parameters:
    ///   - owner: What the sections are (`rightSidebar`), the start of each release's key.
    ///   - planner: The app's sidebar section planner; nil keeps every view for good.
    ///   - save: A hidden mode's view-state record, before its view goes; nil keeps none.
    ///   - drop: Lets a hidden mode's view go.
    public init(owner: String, planner: (any SidebarSectionPlanner)?, save: @escaping @MainActor (Mode) async -> Record?,
                drop: @escaping @MainActor (Mode) -> Void) {
        self.owner = owner
        self.planner = planner
        self.save = save
        self.drop = drop
    }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    /// `mode` shows and each of `others` is hidden; `isNew`: its view was just made (again).
    public func show(_ mode: Mode, hiding others: some Sequence<Mode>, isNew: Bool) {
        for other in others where other != mode { releases[other]?.didHide() }
        release(of: mode)?.didShow()
        if isNew { releases[mode]?.didMake() }
    }

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
            guard let self, let record = await save(mode) else { return }
            records[mode] = record
        } drop: { [weak self] in
            self?.drop(mode)
        }
        releases[mode] = release
        return release
    }
}
