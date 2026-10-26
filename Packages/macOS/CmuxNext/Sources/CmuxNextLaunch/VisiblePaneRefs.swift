import CmuxNextCompat
public import CmuxNextWakeups
import Observation

/// The startup refs of the session restore and of every pane it shows (p08-startup task 013), as
/// Chrome's `StartupObserver` (chrome/browser/after_startup_task_utils.cc) holds startup open until
/// the visible pages finished loading, or `kStartupDelayVisibleTabTimeout` passed.
///
/// - The restore ref is taken at init and released once, at the end of the restore
///   (``restoreFinished(showsWindow:visiblePanes:)``): `noWindow` when the launch shows no window,
///   `noVisiblePane` when its windows show no pane, else `restoreFinished` once each visible pane
///   holds its own ref.
/// - A pane ref is released once, by the first of: its content signal (``PaneState/loadedIdle``,
///   `visiblePaneLoadedIdle`), the pane leaving the visible set (`noVisiblePane`), the bound
///   ``paneBound`` from the end of the restore (`visiblePaneTimedOut`), or the daemon becoming
///   unavailable (`daemonUnavailable`, which ends a restore that never came too).
/// - A pane that becomes visible while refs are still held takes its ref then, as Chrome's observer
///   follows pages that become visible during startup. A pane released once never takes a second ref.
/// - Whatever is still held at the scheduler's failsafe completes startup with `failsafe`.
///
/// The visible panes are read from `visiblePanes`, again on each change of an observable value it
/// reads and on each ``noteChange()`` (content signals that are not observable: a terminal's first
/// content). One update per main turn, however many changes came.
///
/// The app makes one at its composition root with its ``StartupScheduler``; tests pass a recording `hold`.
///
/// ```swift
/// let panes = VisiblePaneRefs(startup: startup)
/// panes.watchUnavailable { daemon.startup.isUnavailable }
/// // The end of the restore:
/// panes.restoreFinished(showsWindow: true) { windows.launchVisiblePanes() }
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

    /// Bumped by ``noteChange()``: the content signals that are not observable themselves.
    @MainActor @Observable
    private final class Changes {
        var count = 0
    }

    private let hold: @MainActor (StaticString) -> Release
    private let bound: DemandTimer
    private let changes = Changes()
    private var restore: Release?
    private var visiblePanes: (@MainActor @Sendable () -> [Pane])?
    /// The pane refs still held, by pane key, in the order they were taken.
    private var pending: [(key: String, release: Release)] = []
    /// Every pane key that took a ref.
    private var taken: Set<String> = []
    private var paneWatch: Task<Void, Never>?
    private var unavailableWatch: Task<Void, Never>?

    /// Takes the restore ref.
    ///
    /// - Parameters:
    ///   - hold: Takes one startup ref by name and returns its release.
    ///   - bound: The visible-pane bound's timer; tests inject a manual clock.
    public init(hold: @escaping @MainActor (StaticString) -> Release,
                bound: DemandTimer = DemandTimer(owner: "VisiblePaneRefs.bound")) {
        self.hold = hold
        self.bound = bound
        restore = hold("WindowManager.restore")
    }

    /// Takes the restore ref of `startup`.
    public convenience init(startup: StartupScheduler, bound: DemandTimer = DemandTimer(owner: "VisiblePaneRefs.bound")) {
        self.init(hold: { [startup] name in
            let ref = startup.hold(name)
            return { ref.release($0) }
        }, bound: bound)
    }

    /// True while the restore ref or a pane ref is held.
    public var isHolding: Bool { restore != nil || !pending.isEmpty }

    /// The keys of the panes still holding startup (`debug.startup`).
    public var pendingPanes: [String] { pending.map(\.key) }

    /// The restore ended: releases its ref, after a ref for each pane in `visiblePanes` when a window shows.
    ///
    /// - Parameters:
    ///   - showsWindow: Whether a window of the launch is on screen.
    ///   - visiblePanes: The panes on screen now, read again on each change until no pane ref is held.
    public func restoreFinished(showsWindow: Bool, visiblePanes: @escaping @MainActor @Sendable () -> [Pane]) {
        guard let restore else { return }
        self.restore = nil
        guard showsWindow else {
            restore(.noWindow)
            return finishIfDone()
        }
        self.visiblePanes = visiblePanes
        let counter = changes
        let (first, later) = ObservationStream<[Pane]>.current { [weak self] in
            _ = counter.count
            return self?.visiblePanes?() ?? []
        }
        take(first)
        // The pane refs are taken first, so this release never ends startup while a pane loads.
        restore(pending.isEmpty ? .noVisiblePane : .restoreFinished)
        guard update(first) else { return }
        bound.schedule(after: Self.paneBound) { @MainActor [weak self] in self?.releasePanes(.visiblePaneTimedOut) }
        // task-owner: self; ends when no pane ref is held (finishIfDone cancels it)
        paneWatch = Task { [weak self] in
            for await panes in later {
                guard let self, self.update(panes) else { return }
            }
        }
    }

    /// A content signal that is not observable came (a terminal was handed content): the visible
    /// panes are read again in a later main turn. O(1); does nothing once no pane ref is held.
    public func noteChange() {
        guard paneWatch != nil else { return }
        changes.count &+= 1
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
        let release = self.restore
        self.restore = nil
        release?(.daemonUnavailable)
        releasePanes(.daemonUnavailable)
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
        for release in left { release(.noVisiblePane) }
        for release in loaded { release(.visiblePaneLoadedIdle) }
        finishIfDone()
        return !pending.isEmpty
    }

    private func releasePanes(_ reason: StartupInProgressRef.Reason) {
        let released = pending
        pending = []
        for entry in released { entry.release(reason) }
        finishIfDone()
    }

    /// No ref is held: the bound and the watches end.
    private func finishIfDone() {
        guard !isHolding else { return }
        bound.cancel()
        paneWatch?.cancel()
        paneWatch = nil
        unavailableWatch?.cancel()
        unavailableWatch = nil
        visiblePanes = nil
    }
}
