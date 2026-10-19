import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextTabs
import Observation

/// What a tab's strip item draws from app state outside the tab's own record: whether it shows
/// the New Tab page, and the badge of the terminal's own theme.
struct TabDrawnValue: Equatable, Sendable {
    var newTabPage = false
    var themeBadge: TabThemeBadge?
}

/// One tab's ``TabDrawnValue``, kept by its own observation (I1, I2, cx-8w027.23). Its inputs are
/// whole collections and connect-time facts (the agent tab store's per-key dictionaries, the home
/// daemon's capabilities and session id, the personal terminal themes): a pane snapshot that read
/// them re-ran on every change of any key, about three unchanged runs per pane in a restore. The
/// cell reads them and changes `value` only when what the tab draws changes; the pane snapshot
/// reads only `value`.
///
/// Made outside a snapshot's evaluation (`PaneController.syncDrawnCells`): the reads of a nested
/// evaluation join the enclosing one, so a cell made inside the snapshot would bring its inputs
/// into the pane's tracking.
@Observable
final class TabDrawnCell {
    private(set) var value: TabDrawnValue
    @ObservationIgnored private var task: Task<Void, Never>?

    init(_ compute: @escaping @MainActor @Sendable () -> TabDrawnValue) {
        let (first, later) = ObservationStream.current(compute)
        value = first
        task = Task { [weak self] in
            for await next in later {
                guard let self else { return }
                if next != value { value = next }
            }
        }
    }

    /// Ends the observation (the tab left the pane, or the pane went).
    func cancel() { task?.cancel() }
}

extension PaneController {
    /// Gives every tab of the pane its drawn-value cell and drops the cells of tabs that left.
    /// Runs outside the snapshot's evaluation: before the first one (init, adopt) and after each
    /// apply, so only a tab that just arrived is computed inside a snapshot, once.
    func syncDrawnCells() {
        let tabs = pane.tabs
        let live = Set(tabs.map(ObjectIdentifier.init))
        for (id, cell) in drawnCells where !live.contains(id) {
            cell.cancel()
            drawnCells[id] = nil
        }
        for tab in tabs where drawnCells[ObjectIdentifier(tab)] == nil {
            drawnCells[ObjectIdentifier(tab)] = TabDrawnCell { [weak self, weak tab] in
                guard let self, let tab else { return TabDrawnValue() }
                return computeDrawn(tab)
            }
        }
    }

    /// Ends every cell (teardown).
    func dropDrawnCells() {
        for cell in drawnCells.values { cell.cancel() }
        drawnCells.removeAll()
    }

    /// What `tab` draws: its cell's value, or (a tab that arrived since the last apply) computed now.
    func drawn(_ tab: TabModel) -> TabDrawnValue {
        drawnCells[ObjectIdentifier(tab)]?.value ?? computeDrawn(tab)
    }

    private func computeDrawn(_ tab: TabModel) -> TabDrawnValue {
        // This pane's own workspace: a known workspace makes the New Tab page check look nothing up.
        let ownWorkspace = workspace?.workspace ?? daemon.store.workspace(containing: pane.handle)
        let titles = TabTitleResolver(services: services, workspace: ownWorkspace?.handle)
        let badge = tab.kind == .browser || tab.kind == .remoteTerminal
            ? nil : services.themes.badge(forTerminal: TerminalThemeKey(machine: daemon.machineID, tab: tab))
        return TabDrawnValue(newTabPage: titles.isNewTabPage(tab), themeBadge: badge)
    }
}
