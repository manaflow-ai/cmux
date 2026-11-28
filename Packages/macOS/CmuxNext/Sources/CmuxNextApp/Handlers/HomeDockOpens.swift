import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextFocus

/// home-chief-pane.md H1 and H5. Home's pinned dock takes the tabs a person drags in (`allow_tabs`,
/// Leo 2026-10-21) but opens nothing in itself, whoever asks: a person, the CLI, MCP or a script.
/// The one rule every tab creator applies (``PaneController/newTerminalTab``,
/// ``PaneBrowserTabOpener``, ``InternalPageTabStore/openStoreTab`` and the actions in
/// ``TabLifecycle``): a tab made in Home's dock moves to a new column right of it. A caller that
/// places the new tab itself (``LinkOpener``, ``AgentBesidePlacement``) passes that placement as the
/// creator's `then`, so nothing moves a tab twice.
@MainActor
enum HomeDockOpens {
    /// Owns the outbound hold from the moment a creator is prepared until it
    /// names a surface. If creation is refused or cancelled before invoking
    /// the callback, releasing this token restores the Home strip immediately.
    @MainActor private final class PlacementHold {
        let outbound: OutboundTab?
        private var completed = false

        init(_ outbound: OutboundTab?) { self.outbound = outbound }

        func made(_ surface: SurfaceID) {
            completed = true
            outbound?.made(surface)
        }

        func cancel() {
            guard !completed else { return }
            completed = true
            outbound?.finish(moved: false)
        }

        func fail() {
            completed = true
            outbound?.finish(moved: false)
        }

        // The creator owns cancellation on every refusal path. Keep deinit
        // nonisolated: this token can be released by an action task.
        nonisolated deinit {}
    }

    /// The end of a placement's move, for a caller that awaits the run's work (`action.run`, the CLI): the run's
    /// answer then says the tab is beside Home, not still on its way out of the dock. Without it a script that
    /// opened a tab from Home's focused dock and split at once was refused ("The agent chat can't be split"):
    /// the split ran before the move had given the new tab the focus (vw4a-ctl-2, HomeFirstOpenTests).
    /// Ends when the move lands or fails, or when the creator drops the placement unused (a refused open).
    private final class MoveEnd: Sendable {
        let ended: AsyncStream<Never>
        private let continuation: AsyncStream<Never>.Continuation

        init() { (ended, continuation) = AsyncStream<Never>.makeStream() }

        func finish() { continuation.finish() }

        deinit { continuation.finish() }
    }

    /// Whether a new tab made in `pane` moves beside it: `pane` is in Home's pinned dock while it
    /// takes tabs. A dock closed to tabs takes none (`dock-column-pinned`): its creators open beside it themselves.
    static func opensBeside(_ pane: PaneModel, services: AppServices) -> Bool {
        services.daemon(for: pane).store.pinnedDock(holding: pane.handle)?.allowsTabs == true
    }

    /// The `then` of a new tab made in `pane`: `then` runs, and a tab made in Home's dock then moves
    /// to a new column right of it, focusing `target` there when `focus` (else the focus stays where
    /// it is). `then` itself anywhere else. Called before the tab is made: the dock's strip leaves it
    /// out until it has moved (``OutboundTab``), so it first shows in the column on the right.
    static func placing(_ pane: PaneModel, services: AppServices, focus: Bool, target: FocusState.Target = .content,
                        then: (@MainActor (SurfaceID) -> Void)?) -> (@MainActor (SurfaceID) -> Void)? {
        guard opensBeside(pane, services: services) else { return then }
        // Arm before the creator issues its intent. Optimistic terminal and page
        // creators insert provisional tabs synchronously, before `then` runs.
        // The creator's own refusal paths release this hold; successful opens
        // name it below before the callback can observe the strip.
        let hold = PlacementHold(services.paneController(for: pane).map { OutboundTab.begin(in: $0) })
        // A caller that awaits the run's work (a script, the CLI) gets its answer once the move has ended.
        let moveEnd = services.registry.isCapturingWork ? MoveEnd() : nil
        if let ended = moveEnd?.ended {
            // task-owner: one-shot; ends with the move (or the placement's release), never holds the placement.
            services.registry.track(Task { for await _ in ended {}; return nil })
        }
        return { [weak services] surface in
            guard let services else { hold.cancel(); then?(surface); moveEnd?.finish(); return }
            hold.made(surface)
            then?(surface)
            if let controller = services.paneController(for: pane) {
                services.linkOpener.moveBeside(surface, from: controller, focus: focus, target: target,
                                                outbound: hold.outbound, then: { moveEnd?.finish() })
            } else {
                hold.fail()
                moveOffscreen(surface, from: pane, services: services)
                moveEnd?.finish()
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

    /// Releases the most recently prepared Home placement when its creator
    /// refuses before invoking the placement callback.
    static func cancel(_ pane: PaneModel, services: AppServices) {
        services.paneController(for: pane).map { OutboundTab.cancelLatest(in: $0) }
    }
}
