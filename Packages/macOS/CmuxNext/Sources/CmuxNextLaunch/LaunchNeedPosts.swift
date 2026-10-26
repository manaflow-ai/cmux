public import CmuxNextWakeups

/// Launch starts that wait for startup to complete unless a visible page needs them, then run right
/// after the first frame (p08-startup task 027: Home and the New Tab page's feeds). Chrome posts work
/// no visible page needs through `AfterStartupTaskUtils::PostTask`
/// (chrome/browser/after_startup_task_utils.cc) and starts what a visible tab needs at once; this is
/// the same split, decided by the page that shows rather than read once at the first frame (the
/// window restore makes its saved windows after it).
///
/// Every start is its own ``StartupScheduler`` post (one service per main turn, as
/// ``LaunchServicePosts``), in the order given. ``post()`` posts them at afterStartup; ``need()``
/// posts them again at afterFirstFrame, once per launch. Each start runs once, at whichever of its two
/// posts runs first, so the starts need not be idempotent. Nothing runs after quit began.
///
/// ```swift
/// let feeds = LaunchNeedPosts(startup: order.startup, starts: [
///     .init("Home.start") { home.start() },
///     .init("ChatsFeed.keepCurrent") { chatsFeed?.keepCurrent() },
/// ])
/// feeds.post()   // after startup
/// feeds.need()   // a Home page or an agent page shows: right after the first frame instead
/// ```
@MainActor
public final class LaunchNeedPosts {
    /// One start: its name in the startup records and signposts, and the work.
    public struct Start {
        /// Its name in the startup records and signposts (`Domain.step`).
        public let name: StaticString
        /// The one service start.
        public let work: @MainActor @Sendable () -> Void

        /// - Parameters:
        ///   - name: Its name in the startup records and signposts.
        ///   - work: The one service start (it runs once).
        public init(_ name: StaticString, _ work: @escaping @MainActor @Sendable () -> Void) {
            self.name = name
            self.work = work
        }
    }

    private weak var startup: StartupScheduler?
    private let starts: [Start]
    private var ran: Set<Int> = []
    /// A page needed the starts (``need()`` posted them at afterFirstFrame).
    public private(set) var isNeeded = false

    /// - Parameters:
    ///   - startup: The launch's scheduler (held weakly: the posts never keep it alive).
    ///   - starts: The starts, in run order.
    public init(startup: StartupScheduler, starts: [Start]) {
        self.startup = startup
        self.starts = starts
    }

    /// The names of the starts that ran, in the order given at init.
    public var started: [String] { ran.sorted().map { starts[$0].name.description } }

    /// Posts the default: every start after startup completes.
    public func post() {
        post(.afterStartup)
    }

    /// A visible page needs the starts: they run right after the first frame (in the next frames once
    /// it passed), before startup completes. Once per launch; a start that already ran does not run again.
    public func need() {
        guard !isNeeded else { return }
        isNeeded = true
        post(.afterFirstFrame)
    }

    /// Returns once the launch's first frame committed (at once when it did, or when quit began): for
    /// async work a shown page starts after it, such as a network read.
    public func afterFirstFrame() async {
        await startup?.afterFirstFrame()
    }

    private func post(_ priority: StartupPriority) {
        guard let startup else { return }
        for index in starts.indices where !ran.contains(index) {
            startup.post(priority, starts[index].name, on: .main) { [weak self] in self?.run(index) }
        }
    }

    private func run(_ index: Int) {
        guard ran.insert(index).inserted else { return }
        starts[index].work()
    }
}
