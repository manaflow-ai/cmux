import CmuxNextCompat
public import CmuxNextWakeups
import Observation

/// The startup refs of the session restore and of every pane it shows (p08-startup task 013), as
/// Chrome's `StartupObserver` (chrome/browser/after_startup_task_utils.cc) holds startup open until
/// the visible pages finished loading, or `kStartupDelayVisibleTabTimeout` passed.
///
/// - The restore ref is taken at init and released once, at the end of the restore
///   (``restoreFinished(windows:)``): `noWindow` when the launch shows no window, `noVisiblePane`
///   when its windows show no pane, else `restoreFinished` once each visible pane holds its own ref.
/// - A pane ref is released once, by the first of: its content signal (``PaneState/loadedIdle``,
///   `visiblePaneLoadedIdle`), the pane leaving the visible set (`noVisiblePane`), the bound
///   ``paneBound`` from the end of the restore (`visiblePaneTimedOut`), or the daemon becoming
///   unavailable (`daemonUnavailable`, which ends a restore that never came too).
/// - A pane that becomes visible while refs are still held takes its ref then, as Chrome's observer
///   follows pages that become visible during startup. A pane released once never takes a second ref.
/// - Whatever is still held at the scheduler's failsafe completes startup with `failsafe`.
/// - It is the one owner of the launch phase's ``StartupPhase/Reference/restoreDone`` and
///   ``StartupPhase/Reference/visiblePageIdle``: each is marked just before the release that ends it,
///   so the phase's settle (the scheduler's launch-phase ref) comes before the last ref, and the
///   completion reason is the restore's, a pane's or the daemon's.
///
/// The visible panes are read from the windows, again on each change of an observable value the read
/// touches and on each ``noteChange()`` (content signals that are not observable: a terminal's first
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

    /// Where a visible pane's content is.
    public enum PaneState: Sendable, Equatable {
        /// Its content has not shown yet (the pane is not mounted, the terminal has no content, the page loads).
        case loading
        /// Its content shows and nothing more is coming at launch (task 105 makes this loaded-idle).
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
    private let changes = Changes()
    private var restore: Release?
    private var windows: (@MainActor @Sendable () -> [Window])?
    /// The pane refs still held, by pane key, in the order they were taken.
    private var pending: [(key: String, release: Release)] = []
    /// Every pane key that took a ref.
    private var taken: Set<String> = []
    /// The objects whose one-shot content signal already calls ``noteChange()`` (``follow(_:signal:)``).
    private var followed: Set<ObjectIdentifier> = []
    /// The windows' notifications that call ``noteChange()`` (``followWindows(_:)``), cancelled once no ref is held.
    var windowEvents: [EventSubscription] = []
    /// Whether the launch's windows ordered behind other apps' show one (``watchCover(of:center:deadlines:sight:startup:images:)``).
    var cover: LaunchCoverWatch?
    private var paneWatch: Task<Void, Never>?
    private var unavailableWatch: Task<Void, Never>?

    /// Takes the restore ref.
    ///
    /// - Parameters:
    ///   - hold: Takes one startup ref by name and returns its release.
    ///   - phase: The launch phase whose restore and visible-page references this marks (nil: none).
    ///   - bound: The visible-pane bound's timer; tests inject a manual clock.
    public init(hold: @escaping @MainActor (StaticString) -> Release, phase: StartupPhase? = nil,
                bound: DemandTimer = DemandTimer(owner: "VisiblePaneRefs.bound")) {
        self.hold = hold
        self.phase = phase
        self.bound = bound
        restore = hold("WindowManager.restore")
    }

    /// Takes the restore ref of `startup`, and marks `phase`'s restore and visible-page references.
    public convenience init(startup: StartupScheduler, phase: StartupPhase?,
                            bound: DemandTimer = DemandTimer(owner: "VisiblePaneRefs.bound")) {
        self.init(hold: { [startup] name in
            let ref = startup.hold(name)
            return { ref.release($0) }
        }, phase: phase, bound: bound)
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
        bound.scheduleOnMain(after: Self.paneBound) { [weak self] in self?.releasePanes(.visiblePaneTimedOut) }
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
        releaseAll(.daemonUnavailable)
    }

    /// Releases every ref still held, the restore's too, with `reason`; no pane takes a ref after.
    func releaseAll(_ reason: StartupInProgressRef.Reason) {
        let released = [restore].compactMap { $0 } + pending.map(\.release)
        restore = nil
        pending = []
        end(released, reason)
    }

    // MARK: Refs

    /// A ref for each pane in `panes` that never took one.
    private func take(_ panes: [Pane]) {
        for pane in panes where taken.insert(pane.key).inserted {
            pending.append((pane.key, hold("Startup.visiblePane")))
        }
    }

    /// Takes refs for newly visible panes, then releases the panes that left (first) and those that
    /// loaded (last, so their reason is the completion's). True while a pane ref is held.
    @discardableResult
    private func update(_ panes: [Pane]) -> Bool {
        if !pending.isEmpty { take(panes) }
        let states = Dictionary(panes.map { ($0.key, $0.state) }, uniquingKeysWith: { first, _ in first })
        var left: [Release] = [], loaded: [Release] = []
        pending.removeAll { entry in
            switch states[entry.key] {
            case nil: left.append(entry.release)
            case .loadedIdle?: loaded.append(entry.release)
            case .loading?: return false
            }
            return true
        }
        markPhaseIfDone()
        for release in left { release(.noVisiblePane) }
        for release in loaded { release(.visiblePaneLoadedIdle) }
        finishIfDone()
        return !pending.isEmpty
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
