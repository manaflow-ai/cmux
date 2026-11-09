public import CmuxNextDesign
public import CmuxNextWakeups
import Foundation

/// Keeps one overlay sync observer registered; removing it (or releasing
/// the observation) unregisters only that observer.
@MainActor
public final class LayoutOverlaySyncObservation {
    private weak var root: LayoutRootView?
    private let id: Int
    private let remove: @MainActor (LayoutRootView, Int) -> Void

    init(root: LayoutRootView, id: Int, remove: @escaping @MainActor (LayoutRootView, Int) -> Void = { $0.overlaySyncObservers[$1] = nil }) {
        self.root = root
        self.id = id
        self.remove = remove
    }

    /// Unregisters the observer now.
    public func cancel() {
        if let root { remove(root, id) }
        root = nil
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            cancel()
        }
    }
}

extension LayoutRootView {
    /// Calls `block` after every overlay sync: a layout pass or an animation
    /// frame moved panes (column scroll spring, divider drag). Never called
    /// while nothing moves. Any number of observers; each lives as long as
    /// its returned observation.
    public func observeOverlaySync(_ block: @escaping () -> Void) -> LayoutOverlaySyncObservation {
        nextOverlaySyncObserver += 1
        overlaySyncObservers[nextOverlaySyncObserver] = block
        return LayoutOverlaySyncObservation(root: self, id: nextOverlaySyncObserver)
    }

    func notifyOverlaySync() {
        for block in overlaySyncObservers.values { block() }
    }

    /// Calls `block` with true when a layout motion starts (a split, close, zoom, New Column, a
    /// released divider or a strip scroll springs) and with false after the frame it lands in:
    /// content that is expensive to move every frame (a Chromium page window) can tell motion
    /// frames from rest. During the motion, each frame's ``observeOverlaySync(_:)`` call carries
    /// ``panesMovedInLastOverlaySync``. Lives as long as the returned observation.
    public func observeLayoutMotion(_ block: @escaping (_ moving: Bool) -> Void) -> LayoutOverlaySyncObservation {
        nextOverlaySyncObserver += 1
        layoutMotionObservers[nextOverlaySyncObserver] = block
        return LayoutOverlaySyncObservation(root: self, id: nextOverlaySyncObserver, remove: { $0.layoutMotionObservers[$1] = nil })
    }

    /// Runs `work` as a task on `queue` once the layout is still: no spring, no divider drag, no live resize of its window.
    /// When it is still now, the task is queued now; else when the motion lands (``setLayoutInMotion(_:)``) or the live
    /// resize ends. A motion that began before the task runs makes it wait again, so it never runs in a motion's frames.
    /// A later call with the same `key` replaces the waiting work. For content that lays out out of sight (a parked page,
    /// RESIZE MAIN BUDGET): hidden work is model only during a motion, then one layout at the final size.
    public func whenStill(_ key: String, on queue: FrameBatchQueue, _ work: @escaping @MainActor () -> Void) {
        stillWork[key] = (queue, work)
        runStillWork()
    }

    /// ``whenStill(_:on:_:)`` once `delay` passed with no later call for `key`. For hidden content that follows changes
    /// which come in every frame with no spring (a sidebar drag or reveal, a window resized in steps): it lays out once,
    /// after the last change, never in a motion's frames. Hidden work only: the wait delays nothing the person sees.
    public func whenSettled(_ key: String, after delay: Duration, on queue: FrameBatchQueue, _ work: @escaping @MainActor () -> Void) {
        let timer = settlingWork[key]?.timer ?? DemandTimer(owner: key)
        settlingWork[key] = (timer, queue, work)
        timer.schedule(after: delay) { @MainActor [weak self] in
            guard let self, let entry = self.settlingWork.removeValue(forKey: key) else { return }
            self.whenStill(key, on: entry.queue, entry.work)
        }
    }

    private var isStill: Bool { !isInLayoutMotion && window?.inLiveResize != true }

    /// Queues the waiting ``whenStill(_:on:_:)`` work when the layout is still.
    func runStillWork() {
        guard isStill, !stillWork.isEmpty else { return }
        let ready = stillWork
        stillWork.removeAll()
        for (key, entry) in ready {
            entry.queue.enqueue { [weak self] in
                guard let self else { return } // the layout is gone: so is what the work would lay out
                guard self.isStill else {
                    // A motion began after it was queued: it waits for that one to land.
                    if self.stillWork[key] == nil { self.stillWork[key] = entry }
                    return
                }
                entry.work()
            }
        }
    }

    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        runStillWork()
    }

    /// Holds `work` until `pane`, which left the layout in a close that still springs, goes when the motion lands (or
    /// comes back), then runs it after that frame's commit. False, holding nothing, when `pane` is not closing.
    /// What a closing pane showed is torn down then, not in the motion's frames (RESIZE VIDEOS F1).
    public func afterClosing(_ pane: PaneID, id: String, _ work: @escaping @MainActor () -> Void) -> Bool {
        context.afterClosing(pane, id: id, work)
    }
}

/// The floating panes' cards (`MainPaneChromeShadeView`): every displayed
/// pane of the shown screens, cut to what this view shows (a column
/// scrolled past its edge, a screen sliding in).
extension LayoutRootView: PaneCardSource {
    public var paneCardsInWindow: [PaneCard] {
        guard window != nil, !isHiddenOrHasHiddenAncestor, !isParkedOrHasParkedAncestor else { return [] }
        let visible = convert(bounds, to: nil)
        return screenViews.values.filter { !$0.isHidden && $0.alphaValue > 0.01 }.flatMap { screen in
            screen.displayedHosts.filter { !$0.isHidden && $0.alphaValue > 0.01 }.compactMap { host in
                let rect = host.cardInWindow.intersection(visible)
                return rect.isEmpty ? nil : PaneCard(rect: rect, radius: PaneChromeGeometry.cornerRadius(for: host.contentRect, style: context.style))
            }
        }
    }

    public func observePaneCards(_ block: @escaping () -> Void) -> AnyObject { observeOverlaySync(block) }
}
