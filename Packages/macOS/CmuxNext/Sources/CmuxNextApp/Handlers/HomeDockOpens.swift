import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextFocus
import struct CmuxNextLayout.DockColumn

/// home-chief-pane.md H1 and H5. Home's pinned dock takes the tabs a person drags in (`allow_tabs`,
/// Leo 2026-10-21) but opens nothing in itself, whoever asks: a person, the CLI, MCP or a script.
/// The one rule every tab creator applies (``PaneController/newTerminalTab``,
/// ``PaneBrowserTabOpener``, ``InternalPageTabStore/openStoreTab`` and the actions in
/// ``TabLifecycle``): a tab made in Home's dock moves to a new column right of it. A caller that
/// places the new tab itself (``LinkOpener``, ``AgentBesidePlacement``) passes that placement as the
/// creator's `then`, so nothing moves a tab twice.
@MainActor
enum HomeDockOpens {
    /// The pinned dock column holding `pane` in `store`, if any.
    static func pinnedDock(holding pane: PaneModel, in store: DaemonStore) -> DockColumn? {
        let handle = pane.handle
        let column = store.workspace(containing: handle)?.screens.lazy.flatMap(\.columns).first { $0.layout.paneIDs.contains(handle) }
        guard let dock = column?.dock.map({ LayoutMapping.dock($0) }), dock.isPinned else { return nil }
        return dock
    }

    /// Whether a new tab made in `pane` moves beside it: `pane` is in Home's pinned dock while it
    /// takes tabs. A dock closed to tabs needs no move: the daemon refuses or reroutes the tab.
    static func opensBeside(_ pane: PaneModel, services: AppServices) -> Bool {
        pinnedDock(holding: pane, in: services.daemon(for: pane).store)?.allowsTabs == true
    }

    /// The `then` of a new tab made in `pane`: `then` runs, and a tab made in Home's dock then moves
    /// to a new column right of it, focusing `target` there when `focus` (else the focus stays where
    /// it is). `then` itself anywhere else.
    static func placing(_ pane: PaneModel, services: AppServices, focus: Bool, target: FocusState.Target = .content,
                        then: (@MainActor (SurfaceID) -> Void)?) -> (@MainActor (SurfaceID) -> Void)? {
        guard opensBeside(pane, services: services) else { return then }
        return { [weak services] surface in
            then?(surface)
            guard let services else { return }
            if let controller = services.paneController(for: pane) {
                services.linkOpener.moveBeside(surface, from: controller, focus: focus, target: target)
            } else {
                moveOffscreen(surface, from: pane, services: services)
            }
        }
    }

    /// A tab made in Home's dock while no window shows Home: it moves to a column right of the
    /// dock, and the focus stays where it is.
    static func moveOffscreen(_ surface: SurfaceID, from pane: PaneModel, services: AppServices) {
        let daemon = services.daemon(for: pane), handle = pane.handle
        services.registry.track(Task {
            let moved = await daemon.request("move-tab-to-column") { connection -> Void in
                _ = try await connection.moveTabToColumn(surface, target: .pane(handle), keepFocus: true)
            } != nil
            return moved ? nil : "home dock: the move beside it failed (see the app log)"
        })
    }
}
