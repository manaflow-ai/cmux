public import CmuxNextActions
public import CmuxNextDaemon

// Zoom and swap in the input's turn (plans/cmux-next/zero-latency.md, "Native actions: the budget contract"): the store
// shows the zoomed pane or the swapped panes before the handler returns, the registry sends the command, and a refusal
// takes the change back and is reported. Every entrypoint of the two verbs returns one of these effects.
extension DaemonService {
    /// Toggle Pane Zoom on `pane`: its screen shows it alone now, or its whole layout again when it was the zoomed
    /// pane. The command names the state the screen now shows (`on` / `off`), so it cannot toggle the other way when
    /// the daemon's zoom is not what this client showed.
    ///
    /// - Parameter pane: The pane to zoom or unzoom.
    /// - Returns: ``ActionEffect/applied(_:)``.
    public func zoomEffect(_ pane: PaneID) -> ActionEffect {
        let zoomed = store.screen(containing: pane)?.zoomedPane != pane
        return intentEffect("zoom-pane", .zoomPane(pane: pane, zoomed: zoomed)) { _ = try await $0.zoomPane(pane, mode: zoomed ? .on : .off) }
    }

    /// `pane` and `other`, two panes of one screen, change places now (`swap-pane` with `target`). For panes that
    /// cannot swap (two screens) nothing shows and the daemon's refusal is reported.
    ///
    /// - Parameters:
    ///   - pane: The pane the swap is run on.
    ///   - other: The pane it changes places with.
    /// - Returns: ``ActionEffect/applied(_:)``.
    public func swapEffect(_ pane: PaneID, with other: PaneID) -> ActionEffect {
        intentEffect("swap-pane", store.swapIntent(of: pane, with: other)) { try await $0.swapPane(pane, with: .pane(other)) }
    }

    /// A directional swap of a shown pane: `pane` and `other`, the pane the window shows on its `direction` side, change
    /// places now. A neighbor still opening (a split the daemon has not confirmed) has no daemon pane to name, so that
    /// swap goes by direction: the daemon finds the pane, after its split on the same connection.
    ///
    /// - Parameters:
    ///   - pane: The pane the swap is run on.
    ///   - other: The pane the window shows on that side.
    ///   - direction: The side.
    /// - Returns: ``ActionEffect/applied(_:)``, or ``ActionEffect/waiting(_:_:)`` for a neighbor still opening.
    public func swapEffect(_ pane: PaneID, with other: PaneID, toward direction: PaneDirection) -> ActionEffect {
        ProvisionalPane.isStandIn(other) ? swapEffect(pane, toward: direction) : swapEffect(pane, with: other)
    }

    /// `pane` swaps with the pane the daemon finds on its `direction` side: for a pane no window lays out. No frame
    /// shows it, and its neighbor is a matter of geometry only the daemon has, so the store changes on the daemon's event.
    ///
    /// - Parameters:
    ///   - pane: The pane the swap is run on.
    ///   - direction: The side its neighbor is on.
    /// - Returns: ``ActionEffect/waiting(_:_:)``.
    public func swapEffect(_ pane: PaneID, toward direction: PaneDirection) -> ActionEffect {
        waitingEffect("swap-pane") { try await $0.swapPane(pane, with: .direction(direction)) } // action-wait-allow: no window lays the pane out, so nothing can show, and only the daemon has the geometry that names its neighbor
    }
}
