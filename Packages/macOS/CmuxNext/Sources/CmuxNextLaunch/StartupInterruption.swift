import CmuxNextDesign
import CmuxNextSignposts

/// Why a launch's startup numbers are not a launch's (p08-startup-108): nobody waited for its window, or something
/// other than the window came first. Chrome's `WasMainWindowStartupInterrupted`
/// (components/startup_metric_utils/browser/startup_metric_utils.cc): a launch in background mode, with a hidden
/// window or with UI before the browser window (`SetNonBrowserUIDisplayed`: the first-run dialog, a profile picker)
/// keeps its trace, and `ShouldLogStartupHistogram` records none of its `Startup.*` durations.
///
/// Each cause is sent once as the instant mark ``mark`` (`launch.interrupted.<cause>`), the first one followed by
/// ``LaunchSlices/interruptedMark``: from then on the first-frame histogram takes no sample (`LaunchSlices`), the hang
/// report's launch histograms leave the launch out (`LaunchAggregate`), and bench-startup.py and startup-queue.py list
/// the run and leave it out of their percentiles.
public nonisolated enum StartupInterruption: String, Sendable, CaseIterable {
    /// Launched hidden (`open -g`, a login item): `NSApp.isHidden` at launch.
    case hidden
    /// The first window goes behind the other apps' windows: a `CMUX_NEXT_NO_ACTIVATE=1` launch with no test screen
    /// (``WindowActivation/plan(_:noActivate:testScreen:)`` orders it back).
    case presentedBehind
    /// The first window was minimized before startup completed.
    case minimized
    /// The first window was shown, then covered or hidden (another Space, Cmd-H, a window over it) before startup
    /// completed: Chrome's first-paint profiler abandons a launch whose contents went hidden.
    case occluded
    /// A local daemon prompt (a pairing, an OSC 52 clipboard read, Restart cmux-tui) before startup completed.
    case daemonPrompt
    /// The user-only setting confirmation (`cmux settings set <key> --confirm`, a managed key) before startup completed.
    case settingConfirmation
    /// Any other cmux dialog before startup completed (the classic migration preview, a confirmation).
    case dialog
    /// The crash-recovery notice ("cmux restarted after a problem") shows on the first window.
    case recoveryNotice
    /// The first launch of this build's bundle (no previous run marker): first-run pages and one-time setup.
    case firstLaunch

    /// The prefix of the instant marks of the causes, `launch.interrupted.<cause>` (bench-startup.py
    /// `INTERRUPTED_INSTANT`).
    public static let markPrefix = LaunchSlices.interruptedMark + "."
    /// The dialog identifiers of the local daemon's prompts.
    public static let daemonPromptDialogs: Set<String> = [
        "cmux.dialog.daemonPairing", "cmux.dialog.terminalClipboardRead", "cmux.dialog.restartDaemon",
    ]
    /// The dialog identifier of the user-only setting confirmation (`UserOnlySettingConfirmation`).
    public static let settingConfirmationDialog = "cmux.dialog.userOnlySetting"

    /// This cause's instant mark.
    public var mark: String { Self.markPrefix + rawValue }

    /// The cause of a cmux dialog opened before startup completed, by its identifier (`CmuxDialogSpec.identifier`).
    public static func cause(ofDialog identifier: String?) -> StartupInterruption {
        guard let identifier else { return .dialog }
        if daemonPromptDialogs.contains(identifier) { return .daemonPrompt }
        return identifier == settingConfirmationDialog ? .settingConfirmation : .dialog
    }
}

/// The launch's interruption causes as they come, from `applicationDidFinishLaunching` to startup completion: pure,
/// the app's ``LaunchInterruptionWatch`` feeds it and sends the marks it returns.
///
/// ```swift
/// var classifier = StartupInterruptionClassifier()
/// send(classifier.launch(.init(hidden: false, firstWindowBehind: true, firstLaunch: false, recoveryNotice: false)))
/// // ["launch.interrupted.presentedBehind", "launch.interrupted"]
/// send(classifier.dialogOpened(identifier: "cmux.dialog.daemonPairing"))  // ["launch.interrupted.daemonPrompt"]
/// classifier.close()  // startup completed: nothing later interrupts it
/// ```
public nonisolated struct StartupInterruptionClassifier: Sendable, Equatable {
    /// What is known at `applicationDidFinishLaunching`, before any window.
    public nonisolated struct Launch: Sendable, Equatable {
        /// `NSApp.isHidden`.
        public var hidden: Bool
        /// The first window is ordered behind the other apps' windows (``firstWindowBehind(noActivate:testScreen:)``).
        public var firstWindowBehind: Bool
        /// No previous run left a run marker.
        public var firstLaunch: Bool
        /// The previous run crashed: the restart notice shows on the first window.
        public var recoveryNotice: Bool

        public init(hidden: Bool, firstWindowBehind: Bool, firstLaunch: Bool, recoveryNotice: Bool) {
            self.hidden = hidden
            self.firstWindowBehind = firstWindowBehind
            self.firstLaunch = firstLaunch
            self.recoveryNotice = recoveryNotice
        }

        /// Whether a launch window is ordered behind the other apps' windows: the placement rule's order for a
        /// presented window (``WindowActivation/plan(_:noActivate:testScreen:)``), so the classifier never
        /// disagrees with where the window went.
        public static func firstWindowBehind(noActivate: Bool, testScreen: Bool) -> Bool {
            WindowActivation.plan(.present, noActivate: noActivate, testScreen: testScreen).order == .orderBack
        }
    }

    /// The causes so far, in the order they came.
    public private(set) var causes: [StartupInterruption] = []
    /// Startup completed: nothing after it interrupts the launch.
    public private(set) var isClosed = false
    /// The first window was reported visible once: only a later report that it is not counts as covered.
    private var firstWindowSeen = false

    public init() {}

    /// Whether the launch is interrupted.
    public var isInterrupted: Bool { !causes.isEmpty }

    /// The launch's own causes, before any window.
    ///
    /// - Returns: The marks to send, in order.
    public mutating func launch(_ launch: Launch) -> [String] {
        var marks: [String] = []
        if launch.hidden { marks += note(.hidden) }
        if launch.firstWindowBehind { marks += note(.presentedBehind) }
        if launch.firstLaunch { marks += note(.firstLaunch) }
        if launch.recoveryNotice { marks += note(.recoveryNotice) }
        return marks
    }

    /// A cmux dialog opened (its `CmuxDialogSpec.identifier`).
    ///
    /// - Returns: The marks to send.
    public mutating func dialogOpened(identifier: String?) -> [String] {
        note(StartupInterruption.cause(ofDialog: identifier))
    }

    /// The first window's state now: when it is presented and at each miniaturize or occlusion notice.
    ///
    /// - Parameters:
    ///   - minimized: `NSWindow.isMiniaturized`.
    ///   - visible: `NSWindow.occlusionState` contains `.visible`. The window server reports it after the window is
    ///     ordered in, so not visible before the first visible report is not a cover.
    /// - Returns: The marks to send.
    public mutating func firstWindow(minimized: Bool, visible: Bool) -> [String] {
        if minimized { return note(.minimized) }
        if visible {
            firstWindowSeen = true
            return []
        }
        return firstWindowSeen ? note(.occluded) : []
    }

    /// Startup completed: later notes change nothing.
    public mutating func close() {
        isClosed = true
    }

    /// Adds `cause` once, before the close.
    ///
    /// - Returns: Its instant mark, then ``LaunchSlices/interruptedMark`` when it is the first cause; empty when it
    ///   was noted before or startup completed.
    private mutating func note(_ cause: StartupInterruption) -> [String] {
        guard !isClosed, !causes.contains(cause) else { return [] }
        causes.append(cause)
        return causes.count == 1 ? [cause.mark, LaunchSlices.interruptedMark] : [cause.mark]
    }
}
