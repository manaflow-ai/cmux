public import CmuxNextDaemon
public import CoreGraphics

/// Floating panes (`floating-panes-v1`): the command that gives a floating pane a frame. A daemon without the
/// capability gets no command.
extension DaemonService {
    /// Whether this daemon has floating panes.
    public var floatsPanes: Bool { supports(DaemonCapability.floatingPanes.rawValue) }

    /// Gives the floating pane `pane` the frame `frame` (fractions of its screen's pane area) and brings it to the
    /// front. The layout shows the frame already; the daemon's next layout confirms it or puts its own back.
    public func setFloatingFrame(of pane: PaneID, to frame: CGRect) {
        guard floatsPanes else { return }
        let wire = FloatingPaneSnapshot.Frame(x: Double(frame.minX), y: Double(frame.minY), w: Double(frame.width), h: Double(frame.height))
        Task { await run("float-pane") { _ = try await $0.floatPane(pane, mode: .on, frame: wire) } }
    }
}
