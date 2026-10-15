public import AppKit
import CmuxNextCompat
import CmuxNextDaemon
public import CmuxNextDaemonService

/// How one window shows the local daemon's first connection: the connecting
/// screen while the window has nothing else to show (cx-jniyz.1), and, when
/// it drew a layout instead (the launch snapshot, a top page), the
/// not-connected notice over it once the startup deadline passed
/// (cx-jniyz.3). One observation of `DaemonService.startup` feeds both, and
/// both offer the same `DaemonRecovery` controls.
@MainActor
public final class DaemonStartupPresence {
    private let daemon: DaemonService
    private let notice: DaemonNotConnectedNotice
    /// The connecting screen while the window has no workspace; nil once one shows.
    public private(set) var connectingView: DaemonConnectingView?
    private var observation: Task<Void, Never>?

    /// - Parameters:
    ///   - host: The view the notice floats in (the window's root, above its content).
    ///   - anchor: The content area the notice sits at the bottom of.
    public init(daemon: DaemonService, host: NSView, anchor: NSView) {
        self.daemon = daemon
        notice = DaemonNotConnectedNotice(recovery: daemon.recovery)
        notice.install(in: host, anchor: anchor)
        // task-owner: ends at teardown, or once connected (startup never fails after that)
        observation = Task { [weak self, daemon] in
            for await startup in ObservationStream({ daemon.startup }) {
                guard let self else { return }
                connectingView?.apply(startup)
                refreshNotice()
                if startup == .connected { return }
            }
        }
    }

    /// The connecting screen for the window's content area, made on first use.
    public func showConnecting() -> DaemonConnectingView {
        if let connectingView { return connectingView }
        let view = DaemonConnectingView(frame: .zero, recovery: daemon.recovery)
        DaemonLaunchTimings.shared.mark("connecting_view_shown")
        view.apply(daemon.startup)
        view.onWindowChange = { [weak self] in self?.refreshNotice() }
        connectingView = view
        return view
    }

    /// A workspace shows: the connecting screen is done. Startup that is still
    /// unavailable shows on the notice instead.
    public func workspaceDidShow() {
        guard let view = connectingView else { return }
        DaemonLaunchTimings.shared.mark("connecting_view_left")
        view.onWindowChange = nil
        connectingView = nil
        refreshNotice()
    }

    public func teardown() {
        observation?.cancel()
        notice.removeFromSuperview()
    }

    private func refreshNotice() {
        notice.apply(daemon.startup, covered: connectingView?.window != nil)
    }
}
