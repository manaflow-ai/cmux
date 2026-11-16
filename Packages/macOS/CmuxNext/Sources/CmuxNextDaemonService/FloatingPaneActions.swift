import AppKit
public import CmuxNextActions
public import CmuxNextDaemon
public import CoreGraphics

/// Floating panes (`floating-panes-v1`): the commands that float a pane, put it back, give it a frame and open a new
/// pane that floats. A daemon without the capability gets no command.
extension DaemonService {
    /// Whether this daemon has floating panes.
    public var floatsPanes: Bool { supports(DaemonCapability.floatingPanes.rawValue) }

    /// Floats `pane` above the tiled panes of its screen, or puts a floating pane back into its place.
    public func toggleFloating(_ pane: PaneID) {
        guard floatsPanes else { return }
        Task { await run("float-pane") { _ = try await $0.floatPane(pane) } }
    }

    /// Gives the floating pane `pane` the frame `frame` (fractions of its screen's pane area) and brings it to the
    /// front. The layout shows the frame already; the daemon's next layout confirms it or puts its own back.
    public func setFloatingFrame(of pane: PaneID, to frame: CGRect) {
        guard floatsPanes else { return }
        let wire = FloatingPaneSnapshot.Frame(x: Double(frame.minX), y: Double(frame.minY), w: Double(frame.width), h: Double(frame.height))
        Task { await run("float-pane") { _ = try await $0.floatPane(pane, mode: .on, frame: wire) } }
    }

    /// Opens a new pane that floats on `pane`'s screen: a split on the right of a tiled pane of the screen, then
    /// `float-pane` on the pane the split made. The split is of `pane`, or of the last tiled pane when `pane` floats.
    public func newFloatingPane(beside pane: PaneID) {
        guard floatsPanes, let screen = store.screen(containing: pane) else { return }
        let floating = Set(screen.floating.map(\.pane))
        let anchor = floating.contains(pane) ? screen.panes.last { !floating.contains($0.handle) }?.handle ?? pane : pane
        let options = SpawnOptions(workspace: store.workspace(containing: pane)?.key)
        Task {
            await run("new-floating-pane") { connection in
                let created = try await connection.split(anchor, direction: .right, options: options)
                if let new = created.pane { _ = try await connection.floatPane(new, mode: .on) }
            }
        }
    }
}

/// The two actions of floating panes. Their titles and keys live here until the action catalog has them.
public enum FloatingPaneActions {
    /// Registers Float Pane and New Floating Pane.
    ///
    /// - Parameters:
    ///   - registry: The registry the actions go into.
    ///   - target: The daemon and the pane an invocation is for (the focused pane, or the pane it names).
    public static func register(into registry: ActionRegistry, target: @escaping @MainActor (ActionInvocation) -> (DaemonService, PaneID)?) {
        registry.register(Action(
            id: "toggleFloatingPane", title: "Float Pane", keywords: ["floating", "float", "tile", "overlay"],
            shortcut: Shortcut("\r", modifiers: [.option, .shift, .command]),
            invoke: { invocation in
                guard let (daemon, pane) = target(invocation) else { return }
                daemon.toggleFloating(pane)
            },
            handler: {}
        ))
        registry.register(Action(
            id: "newFloatingPane", title: "New Floating Pane", keywords: ["floating", "float", "overlay", "scratch"],
            shortcut: Shortcut("n", modifiers: [.control, .shift, .command]),
            invoke: { invocation in
                guard let (daemon, pane) = target(invocation) else { return }
                daemon.newFloatingPane(beside: pane)
            },
            handler: {}
        ))
    }
}
