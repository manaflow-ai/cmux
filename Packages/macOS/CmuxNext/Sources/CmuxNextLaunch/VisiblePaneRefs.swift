import CmuxNextCompat
public import CmuxNextWakeups
import Observation

/// The startup refs of the session restore and of every pane it shows (p08-startup tasks 013 and 105),
/// as Chrome's `StartupObserver` (chrome/browser/after_startup_task_utils.cc) holds startup open until
/// the visible page is loaded-idle (`PageNode::LoadingState::kLoadedIdle`), or
/// `kStartupDelayVisibleTabTimeout` passed.
///
/// - The restore ref is taken at init and released once, at the end of the restore
///   (``restoreFinished(windows:)``): `noWindow` when the launch shows no window, `noVisiblePane`
///   when its windows show no pane, else `restoreFinished` once each visible pane holds its own ref.
/// - A pane ref is released once, by the first of: the pane reaching loaded-idle
///   (`visiblePaneLoadedIdle`: ``PaneState/loadedIdle``, or ``PaneState/shown(output:)`` with no new
///   output for ``quietPeriod``), the pane leaving the visible set while another pane shows
///   (`noVisiblePane`), the bound ``paneBound`` (`visiblePaneTimedOut`, or `noVisiblePane` when it ends
///   while no pane shows), or the daemon becoming unavailable (`daemonUnavailable`, which ends a
///   restore that never came too).
/// - The bound starts at the end of the restore, and again when every visible pane hides (each window
///   closed, minimized or hidden) and when one shows again: a hidden pane does not draw, so its
///   hidden time is not load time. The panes keep their refs while hidden.
/// - A pane that becomes visible while refs are still held takes its ref then, as Chrome's observer
///   follows pages that become visible during startup. A pane released once never takes a second ref.
/// - Whatever is still held at the scheduler's failsafe completes startup with `failsafe`.
/// - It is the one owner of the launch phase's ``StartupPhase/Reference/restoreDone`` and
///   ``StartupPhase/Reference/visiblePageIdle``: each is marked just before the release that ends it,
///   so the phase's settle (the scheduler's launch-phase ref) comes before the last ref, and the
///   completion reason is the restore's, a pane's or the daemon's.
///
/// The visible panes are read from the windows, again on each change of an observable value the read
/// touches and on each ``noteChange()`` (content signals that are not observable: a terminal's
/// content, a page's first paint, a window ordered in, hidden or minimized). One update per main turn,
/// however many changes came.
///
/// The app makes one at its composition root with its ``StartupScheduler`` and ``StartupPhase``;
/// tests pass a recording `hold`.
///
/// ```swift
/// let panes = VisiblePaneRefs(startup: order.startup, phase: order.mainWork.startup)
/// panes.watchUnavailable { daemon.startup.isUnavailable }  // or the daemon's own watch calls daemonUnavailable()
/// // The end of the restore: the launch's windows, read again on each change.
/// panes.followWindows(shownWindows)
/// panes.restoreFinished { launchWindows() }
/// ```
@MainActor
public final class VisiblePaneRefs {
    /// How long a visible pane may take to load, from the end of the restore (Chrome's
    /// `kStartupDelayVisibleTabTimeout` experiment value; p08-startup.md, section 3A).
    public nonisolated static let paneBound: Duration = .seconds(5)

    /// Ends one startup ref with its reason.
    public typealias Release = @MainActor (StartupInProgressRef.Reason) -> Void

    /// How long a pane that shows content must get no new output to be loaded-idle (a terminal: its
    /// snapshot drawn, then 100 ms with no output; p08-startup.md, task 105).
    public nonisolated static let quietPeriod: Duration = .milliseconds(100)

    /// Where a visible pane's content is.
    public enum PaneState: Sendable, Equatable {
        /// Its content has not shown yet (the pane is not mounted, the terminal has no content, the page loads).
        case loading
        /// Its content shows and more may come (a terminal's output after its snapshot): loaded-idle once
        /// `output`, a count that changes with each new content, stays the same for ``quietPeriod``.
        case shown(output: UInt64)
        /// Its content shows and nothing more is coming at launch (a page's load finished).
        case loadedIdle
    }

    /// One visible pane, by its pane key.
    public struct Pane: Sendable, Equatable {
        public let key: String
        public let state: PaneState

        public init(key: String, state: PaneState) {
            self.key = key
            self.state = state
        }
    }

    /// One window of the launch that is on screen, or will be once its content is installed.
    public struct Window: Sendable, Equatable {
        /// What the window shows.
        public enum Content: Sendable, Equatable {
            /// Nothing installed yet: the connecting view, a workspace still mounting or parked, or a
            /// window kept off screen until its content comes.
            case loading
            /// One view fills the window (a top page), with its own key and content signal.
            case page(Pane)
            /// The shown workspace: its panes on screen (mounted in the window and not hidden), and how
            /// many panes its layout has.
            case workspace(onScreen: [Pane], layoutPanes: Int)
        }

        public let id: String
        public let content: Content

        public init(id: String, content: Content) {
            self.id = id
            self.content = content
        }

        /// The panes this window holds startup for. A window with nothing on screen yet stands in as one
        /// loading pane, so it holds startup until its real panes or page show (or the bound ends it);
        /// only a workspace whose layout has no pane shows none.
        public var panes: [Pane] {
            switch content {
            case .loading: [standIn]
            case .page(let pane): [pane]
            case .workspace(let onScreen, let layoutPanes): onScreen.isEmpty && layoutPanes > 0 ? [standIn] : onScreen
            }
        }

        private var standIn: Pane { Pane(key: "window:\(id)", state: .loading) }
    }

    /// Bumped by ``noteChange()``: the content signals that are not observable themselves.
    /// Internal, not private: the `@Observable` macro's conformance extension must reach it.
    @MainActor @Observable
    final class Changes {
        var count = 0
    }

    private let hold: @MainActor (StaticString) -> Release
    private let phase: StartupPhase?
    private let bound: DemandTimer
    /// Reads the shown panes' output every ``quietPeriod`` while one waits to be quiet.
    private let quiet: DemandTimer
    private let changes = Changes()
    private var restore: Release?
    private var windows: (@MainActor @Sendable () -> [Window])?
    /// The pane refs still held, by pane key, in the order they were taken.
    private var pending: [Held] = []
    /// True while pane refs are held and no pane shows (the bound started again when the last one hid).
    private var allHidden = false
    /// Every pane key that took a ref.
    private var taken: Set<String> = []
    /// The objects whose one-shot content signal already calls ``noteChange()`` (``follow(_:signal:)``).
    private var followed: Set<ObjectIdentifier> = []
    /// The windows' notifications that call ``noteChange()`` (``followWindows(_:)``), cancelled once no ref is held.
    var windowEvents: [EventSubscription] = []
    private var paneWatch: Task<Void, Never>?
    private var unavailableWatch: Task<Void, Never>?

    /// One pane ref still held.
    private struct Held {
        let key: String
        let release: Release
        /// The pane's ``PaneState/shown(output:)`` count at the last quiet read; nil while it loads.
        var quietOutput: UInt64?
    }

    /// Takes the restore ref.
    ///
    /// - Parameters:
    ///   - hold: Takes one startup ref by name and returns its release.
    ///   - phase: The launch phase whose restore and visible-page references this marks (nil: none).
    ///   - bound: The visible-pane bound's timer; tests inject a manual clock.
    ///   - quiet: The timer of the shown panes' quiet reads; tests inject a manual clock.
    public init(hold: @escaping @MainActor (StaticString) -> Release, phase: StartupPhase? = nil,
                bound: DemandTimer = DemandTimer(owner: "VisiblePaneRefs.bound"),
                quiet: DemandTimer = DemandTimer(owner: "VisiblePaneRefs.quiet")) {
        self.hold = hold
        self.phase = phase
        self.bound = bound
        self.quiet = quiet
        restore = hold("WindowManager.restore")
    }

    /// Takes the restore ref of `startup`, and marks `phase`'s restore and visible-page references.
    public convenience init(startup: StartupScheduler, phase: StartupPhase?,
                            bound: DemandTimer = DemandTimer(owner: "VisiblePaneRefs.bound"),
                            quiet: DemandTimer = DemandTimer(owner: "VisiblePaneRefs.quiet")) {
        self.init(hold: { [startup] name in
            let ref = startup.hold(name)
            return { ref.release($0) }
        }, phase: phase, bound: bound, quiet: quiet)
    }

    /// True while the restore ref or a pane ref is held.
    public var isHolding: Bool { restore != nil || !pending.isEmpty }

    /// The keys of the panes still holding startup (`debug.startup`).
    public var pendingPanes: [String] { pending.map(\.key) }

    /// The restore ended: releases its ref, after a ref for each visible pane of `windows` when one shows.
    ///
    /// - Parameter windows: The launch's windows on screen (or waiting for their content) now, read again
    ///   on each change until no pane ref is held.
    public func restoreFinished(windows: @escaping @MainActor @Sendable () -> [Window]) {
        guard let restore else { return }
        self.restore = nil
        self.windows = windows
        let counter = changes
        let (shown, later) = ObservationStream<[Window]>.current { [weak self] in
            _ = counter.count
            return self?.windows?() ?? []
        }
        guard !shown.isEmpty else { return end([restore], .noWindow) }
        let first = shown.flatMap(\.panes)
        take(first)
        // The pane refs are taken first, so this release never ends startup while a pane loads.
        end([restore], pending.isEmpty ? .noVisiblePane : .restoreFinished)
        guard update(first) else { return }
        startBound()
        // task-owner: self; ends when no pane ref is held (finishIfDone cancels it)
        paneWatch = Task { [weak self] in
            for await windows in later {
                guard let self, self.update(windows.flatMap(\.panes)) else { return }
            }
        }
    }

    /// A content signal that is not observable came (a terminal was handed content, a window was
    /// ordered in or hidden): the visible panes are read again in a later main turn. O(1); does
    /// nothing once no pane ref is held.
    public func noteChange() {
        guard windows != nil else { return }
        changes.count &+= 1
    }

    /// Reads the visible panes again when `object`'s one-shot content signal fires (a page's first
    /// paint), while the panes are read. `signal` is called once per object, however often it is read.
    public func follow(_ object: AnyObject, signal: (@escaping () -> Void) -> Void) {
        guard windows != nil, followed.insert(ObjectIdentifier(object)).inserted else { return }
        signal { [weak self] in self?.noteChange() }
    }

    /// Watches the daemon until it is unavailable or no ref is held: then no pane can load, and every
    /// ref still held (the restore's when it never came) is released with `daemonUnavailable`.
    public func watchUnavailable(_ isUnavailable: @escaping @MainActor @Sendable () -> Bool) {
        guard isHolding, unavailableWatch == nil else { return }
        // task-owner: self; ends at the first unavailable, or when no ref is held (finishIfDone cancels it)
        unavailableWatch = Task { [weak self] in
            for await unavailable in ObservationStream(isUnavailable) where unavailable {
                self?.unavailableWatch = nil
                self?.daemonUnavailable()
                return
            }
        }
    }

    /// The daemon is unavailable: releases every ref still held with `daemonUnavailable`.
    public func daemonUnavailable() {
        let released = [restore].compactMap { $0 } + pending.map(\.release)
        restore = nil
        pending = []
        end(released, .daemonUnavailable)
    }

    // MARK: Refs

    /// A ref for each pane in `panes` that never took one.
    private func take(_ panes: [Pane]) {
        for pane in panes where taken.insert(pane.key).inserted {
            pending.append(Held(key: pane.key, release: hold("Startup.visiblePane")))
        }
    }

    /// Takes refs for newly visible panes, then releases the panes that left (first) and those that
    /// are loaded-idle (last, so their reason is the completion's). With no pane visible the refs stay
    /// and the bound starts again. True while a pane ref is held.
    ///
    /// - Parameters:
    ///   - panes: The visible panes now.
    ///   - quietRead: A ``quietPeriod`` passed since the last quiet read: a shown pane whose output is
    ///     the same as at that read is loaded-idle.
    @discardableResult
    private func update(_ panes: [Pane], quietRead: Bool = false) -> Bool {
        guard !pending.isEmpty else {
            markPhaseIfDone()
            finishIfDone()
            return false
        }
        guard !panes.isEmpty else {
            if !allHidden {
                allHidden = true
                startBound()
            }
            return true
        }
        if allHidden {
            allHidden = false
            startBound()
        }
        take(panes)
        let states = Dictionary(panes.map { ($0.key, $0.state) }, uniquingKeysWith: { first, _ in first })
        var left: [Release] = [], loaded: [Release] = [], kept: [Held] = []
        var waitsForQuiet = false
        for var held in pending {
            switch states[held.key] {
            case nil:
                left.append(held.release)
            case .loadedIdle?:
                loaded.append(held.release)
            case .shown(let output)? where quietRead && held.quietOutput == output:
                loaded.append(held.release)
            case .shown(let output)?:
                if quietRead { held.quietOutput = output }
                waitsForQuiet = true
                kept.append(held)
            case .loading?:
                held.quietOutput = nil
                kept.append(held)
            }
        }
        pending = kept
        markPhaseIfDone()
        for release in left { release(.noVisiblePane) }
        for release in loaded { release(.visiblePaneLoadedIdle) }
        finishIfDone()
        if waitsForQuiet, !pending.isEmpty {
            quiet.scheduleOnMainIfIdle(after: Self.quietPeriod) { [weak self] in self?.quietReadDue() }
        }
        return !pending.isEmpty
    }

    /// A ``quietPeriod`` passed: the panes are read now, and a shown pane whose output is the same as at
    /// the last quiet read is loaded-idle.
    private func quietReadDue() {
        guard let windows else { return }
        update(windows().flatMap(\.panes), quietRead: true)
    }

    /// Starts the pane bound again from now. At its end the panes still held are released: timed out,
    /// or not visible when no pane shows.
    private func startBound() {
        bound.scheduleOnMain(after: Self.paneBound) { [weak self] in
            guard let self else { return }
            releasePanes(allHidden ? .noVisiblePane : .visiblePaneTimedOut)
        }
    }

    private func releasePanes(_ reason: StartupInProgressRef.Reason) {
        let released = pending.map(\.release)
        pending = []
        end(released, reason)
    }

    /// Releases `refs` (already taken out of `restore` and `pending`) with `reason`, after marking the
    /// phase references they end.
    private func end(_ refs: [Release], _ reason: StartupInProgressRef.Reason) {
        markPhaseIfDone()
        for release in refs { release(reason) }
        finishIfDone()
    }

    /// Marks the phase's restore reference once the restore ref ended, and its visible-page reference
    /// once no ref is held. Called before the releases: the phase settles before the last one.
    private func markPhaseIfDone() {
        guard let phase else { return }
        if restore == nil { phase.markDone(.restoreDone) }
        if !isHolding { phase.markDone(.visiblePageIdle) }
    }

    /// No ref is held: the bound and the watches end.
    private func finishIfDone() {
        guard !isHolding else { return }
        bound.cancel()
        quiet.cancel()
        allHidden = false
        paneWatch?.cancel()
        paneWatch = nil
        unavailableWatch?.cancel()
        unavailableWatch = nil
        windows = nil
        followed = []
        for subscription in windowEvents { subscription.cancel() }
        windowEvents = []
    }
}
