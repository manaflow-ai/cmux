public import CmuxNextWakeups

/// The agent chat tabs' working and needs-input indicators at launch (p08-startup-097): the acpmux watches behind
/// them never connect before the first frame. Chrome starts what a visible tab needs right after the first paint and
/// posts the rest through `AfterStartupTaskUtils::PostTask` (chrome/browser/after_startup_task_utils.cc); this is
/// that split for the indicators, decided by what the windows show.
///
/// - This Mac's turn-state watch, the sidebar's session tree and its chat history are one ``LaunchNeedPosts``:
///   after startup by default; right after the first frame once an agent page shows (``pageShown()``) or a window
///   shows one of this Mac's chat tabs (``checkShown()``).
/// - The Chief home's turn-state watch is another: after startup unless a window shows a Chief subagent tab.
/// - The chat uploads' age sweep is one afterStartup post on the files lane at `.bestEffort`: nobody waits for it.
///
/// ```swift
/// let launch = ChatIndicatorLaunch(startup: order.startup, starts: starts)
/// launch.post()          // at launch, before the first frame
/// launch.pageShown()     // an agent page shows
/// ```
@MainActor
public final class ChatIndicatorLaunch {
    /// Which indicator watches the windows show now.
    public struct Shown: Equatable, Sendable {
        /// A chat tab of this Mac's acpmux: this Mac's turn states, session tree and chat history.
        public var indicators: Bool
        /// A Chief subagent tab: the Chief home's turn states.
        public var chief: Bool

        /// - Parameters:
        ///   - indicators: A chat tab of this Mac's acpmux shows.
        ///   - chief: A Chief subagent tab shows.
        public init(indicators: Bool = false, chief: Bool = false) {
            self.indicators = indicators
            self.chief = chief
        }
    }

    /// The watches' starts (the app's, or a test's fakes): each runs once, in its own post.
    public struct Starts {
        /// Starts this Mac's acpmux turn-state watch (one connection).
        public var turnStates: @MainActor @Sendable () -> Void
        /// Starts the sidebar's session tree feed.
        public var sessionTree: @MainActor @Sendable () -> Void
        /// Starts the sidebar's chat history (it observes the Chats feed, which connects it).
        public var chatHistory: @MainActor @Sendable () -> Void
        /// Starts the Chief home's acpmux turn-state watch (one connection).
        public var chiefTurnStates: @MainActor @Sendable () -> Void
        /// Deletes the chat uploads past their age; it blocks on the disk and runs on the files lane.
        public var uploadSweep: @Sendable () -> Void
        /// What the windows show now; it must not block.
        public var shown: @MainActor @Sendable () -> Shown

        /// - Parameters:
        ///   - turnStates: Starts this Mac's acpmux turn-state watch.
        ///   - sessionTree: Starts the sidebar's session tree feed.
        ///   - chatHistory: Starts the sidebar's chat history.
        ///   - chiefTurnStates: Starts the Chief home's acpmux turn-state watch.
        ///   - uploadSweep: Deletes the chat uploads past their age (blocking).
        ///   - shown: What the windows show now.
        public init(turnStates: @escaping @MainActor @Sendable () -> Void, sessionTree: @escaping @MainActor @Sendable () -> Void,
                    chatHistory: @escaping @MainActor @Sendable () -> Void, chiefTurnStates: @escaping @MainActor @Sendable () -> Void,
                    uploadSweep: @escaping @Sendable () -> Void, shown: @escaping @MainActor @Sendable () -> Shown) {
            self.turnStates = turnStates
            self.sessionTree = sessionTree
            self.chatHistory = chatHistory
            self.chiefTurnStates = chiefTurnStates
            self.uploadSweep = uploadSweep
            self.shown = shown
        }
    }

    private weak var startup: StartupScheduler?
    private let indicators: LaunchNeedPosts
    private let chief: LaunchNeedPosts
    private let uploadSweep: @Sendable () -> Void
    private let shown: @MainActor @Sendable () -> Shown
    private var posted = false
    /// A ``checkShown()`` post has not run yet.
    private var checkQueued = false

    /// - Parameters:
    ///   - startup: The launch's scheduler (held weakly: the posts never keep it alive).
    ///   - starts: The watches' starts.
    public init(startup: StartupScheduler, starts: Starts) {
        self.startup = startup
        indicators = LaunchNeedPosts(startup: startup, starts: [
            .init("AgentTurnStates.start", needed: "AgentTurnStates.startNeeded", starts.turnStates),
            .init("SidebarSessionTree.start", needed: "SidebarSessionTree.startNeeded", starts.sessionTree),
            .init("SidebarChatHistory.start", needed: "SidebarChatHistory.startNeeded", starts.chatHistory),
        ])
        chief = LaunchNeedPosts(startup: startup, starts: [
            .init("ChiefTurnStates.start", needed: "ChiefTurnStates.startNeeded", starts.chiefTurnStates),
        ])
        uploadSweep = starts.uploadSweep
        shown = starts.shown
    }

    /// The names of the watch starts that ran, this Mac's first.
    public var started: [String] { indicators.started + chief.started }

    /// Whether something shown moved this Mac's watches to right after the first frame.
    public var indicatorsNeeded: Bool { indicators.isNeeded }

    /// Whether a Chief subagent tab moved the Chief home's watch to right after the first frame.
    public var chiefNeeded: Bool { chief.isNeeded }

    /// Posts the launch's default: every watch after startup, the upload sweep after startup on the files lane at
    /// `.bestEffort`, and one look right after the first frame at what the windows show. Once.
    public func post() {
        guard !posted, let startup else { return }
        posted = true
        indicators.post()
        chief.post()
        startup.post(.afterStartup, "AgentChatUploads.sweep", on: .lane(.files, .bestEffort), uploadSweep)
        checkShown()
    }

    /// An agent page shows: this Mac's watches right after the first frame, and a look at whether a Chief tab
    /// shows too.
    public func pageShown() {
        indicators.need()
        checkShown()
    }

    /// Posts one look, right after the first frame (in the next frames once it passed), at what the windows show;
    /// each watch they show starts then instead of after startup. One look queued at a time; none once startup
    /// completed (the watches' own posts then run) or both watches are needed.
    public func checkShown() {
        guard !checkQueued, !(indicators.isNeeded && chief.isNeeded), let startup, startup.completion == nil else { return }
        checkQueued = true
        startup.post(.afterFirstFrame, "ChatIndicators.shown", on: .main) { [weak self] in
            guard let self else { return }
            checkQueued = false
            let now = shown()
            if now.indicators { indicators.need() }
            if now.chief { chief.need() }
        }
    }
}
