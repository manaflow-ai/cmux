import CmuxNextActions
public import CmuxNextDaemon

/// The focus of the window that shows a pane, for an act that makes a pane there. The focus state is the app's: the
/// app gives the 2 functions of its window.
public struct NewPaneFocus {
    /// Starts an intent of the person whose result comes later. It returns the intent's generation.
    let begin: @MainActor () -> UInt64
    /// Asks for the focus on the tab of the surface it gets, once the window has that tab. The window refuses the
    /// request when the person acted after the intent of the generation it gets.
    let expect: @MainActor (SurfaceID, UInt64) -> Void

    /// - Parameters:
    ///   - begin: Starts an intent in the window and returns its generation.
    ///   - expect: Asks the window for the focus on a surface, for the intent of a generation.
    public init(begin: @escaping @MainActor () -> UInt64, expect: @escaping @MainActor (SurfaceID, UInt64) -> Void) {
        self.begin = begin
        self.expect = expect
    }

    /// Starts the intent now, in the turn of the person's key, as a split starts it before its request goes.
    ///
    /// - Returns: The request that asks for the focus on a surface with the generation of this intent.
    @MainActor func started() -> @MainActor (SurfaceID) -> Void {
        let generation = begin(), expect = expect
        return { expect($0, generation) }
    }
}

/// New Floating Pane as one unit: a split on the right of a tiled pane of the screen, then `float-pane` on the pane
/// that the split made. The new pane gets the focus (decision 2026-11-16). The act ends with a floating pane or with
/// an error that a person sees, never with a tiled pane and no error (decision 2026-11-16). The 2 requests and the
/// focus request are closures, so a test runs the act with stand-ins and no daemon.
struct NewFloatingPane {
    /// The store that holds the screens.
    let store: DaemonStore
    /// `split` on the right of the pane it gets; it returns the daemon's reply once the store holds the new pane.
    let split: @MainActor (PaneID) async throws -> SurfaceCreated
    /// `float-pane` with `mode: on` for the pane it gets.
    let float: @MainActor (PaneID) async throws -> Void
    /// Asks the window for the focus on the tab of the surface it gets, as a split asks for its new pane
    /// (`NewPaneFocus.started`).
    let focus: @MainActor (SurfaceID) -> Void

    /// The pane that the split goes to: `pane` when it is tiled and outside each dock, else the last tiled pane of
    /// `screen` outside each dock (the daemon refuses a split in a docked column). Nil when the screen has no such pane.
    static func anchor(for pane: PaneID, on screen: ScreenModel) -> PaneID? {
        let floating = Set(screen.floating.map(\.pane))
        let docked = Set(screen.columns.filter { $0.dock != nil }.flatMap(\.layout.paneIDs))
        let isAnchor: (PaneID) -> Bool = { !floating.contains($0) && !docked.contains($0) }
        return isAnchor(pane) ? pane : screen.panes.last { isAnchor($0.handle) }?.handle
    }

    /// Runs the act for the focused pane `pane`: the split, the focus request for the pane that the split made, then
    /// the float of that pane. The daemon's reply names the new tab's surface and no numeric pane, so the pane is the
    /// store's pane that holds that surface.
    ///
    /// - Throws: ``ActionFailure`` with the notice's text when the screen has no pane that a split can go to, or
    ///   when the store has no pane for the reply; the error of a request that the daemon refused.
    func run(beside pane: PaneID) async throws {
        guard let screen = store.screen(containing: pane), let anchor = Self.anchor(for: pane, on: screen) else {
            throw ActionFailure(message: FloatingPaneStrings.noTiledPane)
        }
        let created = try await split(anchor)
        guard let new = store.pane(containing: created.surface)?.handle else {
            throw ActionFailure(message: FloatingPaneStrings.notFloated)
        }
        // As a split: the new pane gets the focus when the reply names it. A float that the daemon refuses leaves a
        // tiled pane that has the focus, as a split does.
        focus(created.surface)
        try await float(new)
    }

    /// Starts the act on `daemon` for the focused pane `pane`, with the daemon's 2 requests.
    ///
    /// - Parameter window: The focus of the window that shows `pane`; nil when no window shows it. Its intent starts
    ///   in this call, before the first request goes.
    /// - Returns: The act's work: nil when the pane floats, else the failure. The caller gives it to the action
    ///   registry, so a key run shows the failure and a caller that waits gets it.
    static func start(on daemon: DaemonService, beside pane: PaneID, window: NewPaneFocus?) -> ActionWork {
        let label = "new-floating-pane"
        let focus = window?.started()
        let options = SpawnOptions(workspace: daemon.store.workspace(containing: pane)?.key)
        // The ticket opens now, as `send` opens it: a caller that waits for the action's scope waits for the 2 requests.
        let ticket = daemon.openTicket(label)
        return Task {
            do {
                guard daemon.floatsPanes else { throw ActionFailure.needsDaemonCapability(DaemonCapability.floatingPanes.rawValue) }
                guard let connection = daemon.connection else { throw DaemonError.notConnected }
                let store = daemon.store
                let act = NewFloatingPane(
                    store: store,
                    split: { anchor in
                        let target = try await store.daemonTarget(anchor)
                        let created = try await connection.split(target, direction: .right, options: options)
                        // The store holds each event that the daemon sent before the reply, so it holds the new pane.
                        await store.applied(.generate(), connection: connection)
                        return created
                    },
                    float: { _ = try await connection.floatPane($0, mode: .on) },
                    focus: { surface in if let focus { focus(surface) } }
                )
                try await act.run(beside: pane)
                await daemon.closeTicket(ticket, label: label, error: nil, replying: connection)
                return nil
            } catch {
                daemon.logCommandFailure(label, error: error)
                await daemon.closeTicket(ticket, label: label, error: error)
                return daemon.workFailure(label, error)
            }
        }
    }
}
