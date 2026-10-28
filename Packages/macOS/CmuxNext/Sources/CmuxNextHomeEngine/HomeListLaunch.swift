import CmuxNextLaunch
public import CmuxNextWakeups
public import Foundation
public import Observation

/// The Home list's launch read on the main thread: the steps that need the last launch's list
/// (the seed of the store, the inboxes and the roster, then the store's start) run in this turn when the read has
/// ended, else on its landing, in the order they were asked. Nothing waits and no file is read on main; the Home
/// list draws the theme background until ``isLanded`` (p08-startup.md: a step that needs a read that is not done
/// runs on the read's completion event, as Chrome runs a profile's dependents from its loaded callback,
/// chrome/browser/profiles/profile_impl.cc).
@Observable @MainActor
public final class HomeListLaunch {
    /// The read: the app's from `main` when it reads this owner's files, else one started here.
    @ObservationIgnored public let read: HomeListLaunchRead
    /// The read landed and every step asked before it ran (the store, the inboxes and the roster are seeded):
    /// a Home list draws its rows from here on, all in one frame, and only the theme background before. Observed.
    public private(set) var isLanded = false
    @ObservationIgnored private let landed = LaunchReadEvent("Home.listRead")
    @ObservationIgnored private var value: HomeListLaunchRead.Value?
    @ObservationIgnored private var hopping = false
    @ObservationIgnored private let work: BackgroundWork
    @ObservationIgnored private let mainWork: MainWorkScheduler

    /// - Parameters:
    ///   - read: The launch's read (`AppEnvironment.homeListRead`); taken when it reads `owner`'s files under `caches`.
    ///   - owner: The Chief owner of the Home list (`ChiefHome.session`).
    ///   - caches: The folder of the service's Home caches.
    ///   - work: The app's blocking-work lanes: a read started here runs on them.
    ///   - mainWork: The main-thread scheduler the landing is posted on.
    public init(read: HomeListLaunchRead?, owner: String, caches: URL, work: BackgroundWork, mainWork: MainWorkScheduler) {
        if let read, read.reads(owner: owner, caches: caches) {
            self.read = read
        } else {
            self.read = HomeListLaunchRead.start(owner: owner, caches: caches, on: work)
        }
        self.work = work
        self.mainWork = mainWork
    }

    /// Runs `step` with what the files held: at once when the read has ended, else when it lands.
    public func whenRead(_ step: @escaping @MainActor (HomeListLaunchRead.Value) -> Void) {
        if value == nil, let ended = read.value { land(ended) }
        if let value { return step(value) }
        landed.post { [weak self] in
            if let value = self?.value { step(value) }
        }
        hopWhenRead()
    }

    /// One wait off main for the read, then one visible main post that lands it.
    private func hopWhenRead() {
        guard !hopping else { return }
        hopping = true
        let read = read, mainWork = mainWork
        // task-owner: one launch read's completion; ends after its one main post
        work.task(.userBlocking) { [weak self] in
            let value = await read.finished()
            mainWork.postFromAnyThread(.visible, owner: "Home.listRead") { [weak self] in self?.land(value) }
        }
    }

    private func land(_ value: HomeListLaunchRead.Value) {
        guard self.value == nil else { return }
        self.value = value
        landed.signal()
        isLanded = true
    }
}
