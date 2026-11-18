public import CmuxNextDaemon
public import CoreGraphics

/// Floating panes (`floating-panes-v1`): the command that brings a floating pane to the front and can give it a
/// frame. A daemon without the capability gets no command.
extension DaemonService {
    /// Whether this daemon has floating panes.
    public var floatsPanes: Bool { supports(DaemonCapability.floatingPanes.rawValue) }

    /// Brings the floating pane `pane` to the front. With `frame` (fractions of its screen's pane area) the pane
    /// takes that frame: the layout shows it already, and the daemon's next layout confirms it or puts its own
    /// back. With no frame the command names none, so the pane keeps the frame that the daemon has.
    public func bringFloatingPaneToFront(_ pane: PaneID, frame: CGRect?) {
        guard floatsPanes else { return }
        let wire = frame.map { FloatingPaneSnapshot.Frame(x: Double($0.minX), y: Double($0.minY), w: Double($0.width), h: Double($0.height)) }
        Task { await run("float-pane") { _ = try await $0.request(FloatPaneRequest(pane: pane, mode: .on, frame: wire)) } }
    }
}
