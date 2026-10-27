public import CmuxNextWakeups

/// Launch starts that wait for startup to complete unless a visible page needs them, then run right
/// after the first frame (p08-startup task 027: Home and the New Tab page's feeds). Chrome posts work
/// no visible page needs through `AfterStartupTaskUtils::PostTask`
/// (chrome/browser/after_startup_task_utils.cc) and starts what a visible tab needs at once; this is
/// the same split, decided by the page that shows rather than read once at the first frame (the
/// window restore makes its saved windows after it).
///
/// Every start is its own ``StartupScheduler`` post (one service per main turn, as
/// ``LaunchServicePosts``), in the order given. ``post()`` queues one afterStartup post at a time:
/// each runs its start and then posts the next start not run yet, so a start a page already ran
/// leaves no queued copy behind (at most one empty post when ``need()`` ran them all). ``need()``
/// posts every start not run yet at afterFirstFrame, under its ``Start/neededName``, once per launch.
/// Each start runs once, at whichever of its posts runs first, so the starts need not be idempotent.
/// Nothing runs after quit began.
///
/// ```swift
/// let feeds = LaunchNeedPosts(startup: order.startup, starts: [
///     .init("Home.start", needed: "Home.startNeeded") { home.start() },
///     .init("ChatsFeed.keepCurrent", needed: "ChatsFeed.keepCurrentNeeded") { chatsFeed?.keepCurrent() },
/// ])
/// feeds.post()   // after startup
/// feeds.need()   // a Home page or an agent page shows: right after the first frame instead
/// ```
@MainActor
public final class LaunchNeedPosts {
    /// One start: its names in the startup records and signposts, and the work.
    public struct Start {
        /// Its name when it runs after startup (`Domain.step`).
        public let name: StaticString
        /// Its name when a page needed it right after the first frame (`Domain.stepNeeded`, as
        /// `Cloud.startNeeded`), so the records show which path ran it.
        public let neededName: StaticString
        /// The one service start.
        public let work: @MainActor @Sendable () -> Void

        /// - Parameters:
        ///   - name: Its name when it runs after startup.
        ///   - neededName: Its name when a page needed it.
        ///   - work: The one service start (it runs once).
        public init(_ name: StaticString, needed neededName: StaticString, _ work: @escaping @MainActor @Sendable () -> Void) {
            self.name = name
            self.neededName = neededName
            self.work = work
        }
    }

    private weak var startup: StartupScheduler?
    private let starts: [Start]
    private var ran: Set<Int> = []
    private var posted = false
    /// A page needed the starts (``need()`` posted them at afterFirstFrame).
    public private(set) var isNeeded = false

    /// - Parameters:
    ///   - startup: The launch's scheduler (held weakly: the posts never keep it alive).
    ///   - starts: The starts, in run order.
    public init(startup: StartupScheduler, starts: [Start]) {
        self.startup = startup
        self.starts = starts
    }

    /// The starts' after-startup names, in run order.
    public var names: [String] { starts.map(\.name.description) }

    /// The names of the starts that ran, in the order given at init.
    public var started: [String] { ran.sorted().map { starts[$0].name.description } }

    /// Posts the default: the starts after startup completes, one per post. Once.
    public func post() {
        guard !posted else { return }
        posted = true
        postAfterStartup(from: 0)
    }

    /// A visible page needs the starts: they run right after the first frame (in the next frames once
    /// it passed), before startup completes. Once per launch; a start that already ran does not run again.
    public func need() {
        guard !isNeeded else { return }
        isNeeded = true
        guard let startup else { return }
        for index in starts.indices where !ran.contains(index) {
            startup.post(.afterFirstFrame, starts[index].neededName, on: .main) { [weak self] in self?.run(index) }
        }
    }

    /// Returns once the launch's first frame committed (at once when it did, or when quit began): for
    /// async work a shown page starts after it, such as a network read.
    public func afterFirstFrame() async {
        await startup?.afterFirstFrame()
    }

    /// Posts the first start at or after `index` not run yet; it posts the one after it when it runs.
    private func postAfterStartup(from index: Int) {
        guard let startup, let next = (index..<starts.count).first(where: { !ran.contains($0) }) else { return }
        startup.post(.afterStartup, starts[next].name, on: .main) { [weak self] in
            self?.run(next)
            self?.postAfterStartup(from: next + 1)
        }
    }

    private func run(_ index: Int) {
        guard ran.insert(index).inserted else { return }
        starts[index].work()
    }
}
