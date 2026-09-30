import AppKit
import CmuxNextControl
import CmuxNextDaemon
import Observation
import os

/// Publishes the control snapshot (architecture.md 5a) after the model
/// settles: at most once per display frame, and only when something the
/// snapshot reads changed.
///
/// The build runs inside Observation tracking, so any daemon record,
/// window state, focus, or settings property it read schedules the next
/// publish; key-window changes (not observable) and every main-actor work
/// queue frame invalidate explicitly. Readers never touch main-actor state:
/// they get the last published value.
@MainActor
final class ControlSnapshotPublisher {
    private let router: ControlRouter
    private unowned let services: AppServices
    private let frames: any ControlFrameSource
    private var isScheduled = false
    private var isStopped = false
    private var observers: [any NSObjectProtocol] = []
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "control.snapshot")

    init(router: ControlRouter, services: AppServices, frames: any ControlFrameSource) {
        self.router = router
        self.services = services
        self.frames = frames
    }

    func start() {
        // Read-your-writes for local state: a CLI mutation's effect on focus
        // or selection is in the snapshot before the next request is read.
        router.workQueue.setAfterFrame { [weak self] in self?.publishNow() }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidate() }
            })
        }
        publishNow()
    }

    func stop() {
        isStopped = true
        router.workQueue.setAfterFrame(nil)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Schedules one publish on the next frame (coalesced).
    func invalidate() {
        guard !isScheduled, !isStopped else { return }
        isScheduled = true
        frames.scheduleFrame { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            self.publishNow()
        }
    }

    /// Publishes now. Compat intents call this so a CLI read that follows a
    /// CLI write sees it (the scheduled publish lands a frame later).
    func publishNow() {
        guard !isStopped else { return }
        let started = ContinuousClock.now
        let (topology, settings) = withObservationTracking {
            (buildTopology(), services.settings?.snapshot.root)
        } onChange: { [weak self] in
            // Runs synchronously inside the mutation; publish after it lands.
            Task { @MainActor in self?.invalidate() }
        }
        router.snapshots.publish { snapshot in
            snapshot.topology = topology
            snapshot.settings = settings
        }
        let elapsed = ContinuousClock.now - started
        if elapsed > .milliseconds(2) {
            logger.debug("control snapshot took \(elapsed.components.attoseconds / 1_000_000_000_000_000) ms for \(topology.tabCount) tabs")
        }
    }

    private func buildTopology() -> ControlTopology {
        let windows: WindowManager = services.windows
        var topology = ControlTopologyMapper.topology(store: services.daemon.store) { [services] pane in
            services.paneController(for: pane)?.selectedTab?.id
        }
        if case .unavailable(let error) = services.daemon.startup { topology.daemonFailure = error.description }
        topology.windows = windows.controllers.map { controller in
            ControlWindowInfo(
                id: controller.state.id,
                workspaceID: controller.state.workspaceID,
                workspaceIDs: windows.registry.members(of: controller.state.id),
                isKey: controller.window?.isKeyWindow ?? false,
                isVisible: controller.window?.isVisible ?? false,
                focusedPaneID: controller.focusedPane?.pane.id
            )
        }
        if let active = windows.active {
            let pane = active.focusedPane
            topology.focus = ControlFocus(windowID: active.state.id, workspaceID: active.state.workspaceID,
                                          paneID: pane?.pane.id, tabID: pane?.selectedTab?.id)
        }
        return topology
    }
}
