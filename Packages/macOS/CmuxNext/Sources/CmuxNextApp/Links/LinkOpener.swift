import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextSettings
import CmuxNextWakeups

/// Opens what the person opened from a pane where ``LinkOpenPlacement`` says
/// (`layout.linkPlacement`): every link and path a terminal, an agent chat, Home or a page opens
/// in cmux comes here (``LinkRouter/openInCmux`` for web links, ``openFile(_:from:)`` for files,
/// ``openFolder(_:from:)`` for folders), so no surface picks its own pane.
///
/// A new tab for the pane on the right opens there, selected and focused. A new split or column is
/// made by opening the tab unselected in the source pane and moving it there in one daemon move
/// (`TabMoves`), the way an agent's tab reaches the column beside its chat (``AgentBesidePlacement``):
/// the source keeps showing what it showed.
@MainActor
final class LinkOpener {
    /// Opens the item in `pane`. `placed` is nil for a tab that shows in `pane` now (selected and
    /// focused); else the tab must open unselected and report its surface to `placed`, which moves
    /// it. Returns false when nothing opened (the opener reported why).
    typealias Make = @MainActor (_ pane: PaneController, _ placed: (@MainActor (SurfaceID) -> Void)?) -> Bool

    /// How long a move waits for the store to list the new tab.
    static let listLimit: Duration = .seconds(30)

    /// The app's services (they own this opener and outlive it).
    private weak var services: AppServices?
    /// The setting, read on every open (``LinkPlacement/fallback`` before settings load).
    var placement: () -> LinkPlacement

    init(services: AppServices) {
        self.services = services
        placement = { [weak services] in services?.settings?.snapshot.linkPlacement ?? .fallback }
    }

    /// The pane a link opened from tab `key` (a tab id or resource id) starts from: the pane
    /// showing that tab, else the active window's focused pane.
    func source(tab key: String?) -> PaneController? {
        guard let services else { return nil }
        if let key, let (_, pane) = services.locateTab(key), let controller = services.paneController(for: pane) { return controller }
        if let key, let controller = services.paneController(showingTab: key) { return controller }
        return services.windows.active?.focusedPane
    }

    /// The pane showing `view` (a Home or agent chat, a cmux page) in any window, or nil: a click
    /// in it opens from that pane, never from whichever pane has focus.
    func source(containing view: NSView) -> PaneController? {
        guard let services else { return nil }
        return source(containing: view, in: services.windows.controllers.flatMap { $0.content.map { Array($0.panes.values) } ?? [] })
    }

    /// Pure: the pane among `panes` whose view holds `view`, or nil.
    func source(containing view: NSView, in panes: [PaneController]) -> PaneController? {
        panes.first { view === $0.view || view.isDescendant(of: $0.view) }
    }

    /// Where an item opened from `source` lands now, by ``LinkOpenPlacement``.
    func target(from source: PaneController) -> LinkOpenPlacement<LayoutPaneID>.Target {
        let right = source.workspace.flatMap { content in
            PaneHandlers.neighbor(of: source.layoutPaneID, direction: .right, in: content).flatMap { id in
                content.panes[id]?.stripModel.showsNewTabButton == true ? id : nil
            }
        }
        return LinkOpenPlacement(setting: placement())
            .target(source: source.layoutPaneID, takesTabs: source.stripModel.showsNewTabButton, right: right)
    }

    /// Opens through `make` where the rule puts it. `background`: the opened tab takes no focus.
    /// False with no source pane (no window) or when `make` refused.
    @discardableResult
    func open(from source: PaneController?, background: Bool = false, _ make: Make) -> Bool {
        guard let source = source ?? services?.windows.active?.focusedPane else { return false }
        switch target(from: source) {
        case .pane(let id):
            return make(id == source.layoutPaneID ? source : source.workspace?.panes[id] ?? source, nil)
        case .splitRight:
            return make(source) { [weak self, weak source] surface in
                guard let self, let source else { return }
                self.move(surface, from: source, to: .split(.right), focus: !background)
            }
        case .newColumn:
            return make(source) { [weak self, weak source] surface in
                guard let self, let source else { return }
                self.move(surface, from: source, to: .besideColumn, focus: !background)
            }
        case .besideDock:
            // The daemon makes a tab aimed at a lone pinned dock in a new column right of it.
            return make(source, nil)
        }
    }

    /// A web link in a cmux browser tab (``LinkRouter/openInCmux``).
    func openWeb(_ url: URL, from source: PaneController?, background: Bool) {
        open(from: source, background: background) { pane, placed in
            pane.newBrowserTab(url: url, background: background || placed != nil, then: placed)
        }
    }

    /// A file: the Markdown page, the code editor or the browser tab's preview (``FilePageOpener``).
    /// A tab that already shows the file is selected where it is. False when it did not open (the
    /// refusal shows).
    @discardableResult
    func openFile(_ file: URL, from source: PaneController?, markdown: Bool = false) -> Bool {
        open(from: source) { pane, placed in
            pane.services.viewers.openFile(file, in: pane, markdown: markdown, placed: placed)
        }
    }

    /// A folder: a terminal there. In a new split it is the split's own terminal (Split Right with
    /// that folder); a column or the pane on the right gets a terminal tab.
    func openFolder(_ path: String, from source: PaneController?) {
        guard let source = source ?? services?.windows.active?.focusedPane else { return }
        switch target(from: source) {
        case .pane(let id):
            (source.workspace?.panes[id] ?? source).newTerminalTab(cwd: path)
        case .besideDock:
            source.workspace?.newColumn(after: source.layoutPaneID, options: SpawnOptions(cwd: path, workspace: source.workspace?.workspace.key))
        case .splitRight, .newColumn:
            var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: source.paneKey),
                                              arguments: ["cwd": .string(path)], origin: .user)
            invocation.opensTerminal = true
            source.services.registry.perform("splitRight", invocation: invocation)
        }
    }

    /// Where ``move(_:from:to:focus:)`` takes a new tab.
    enum Destination {
        /// A new split of the tab's pane on this side.
        case split(PaneEdge)
        /// A new column right of the tab's pane, sized and placed like an agent's beside its chat.
        case besideColumn
        /// A new column after the daemon column (nil: after the tab's own column).
        case column(after: DaemonColumnID?)
        /// A new dock band on this edge of the tab's screen.
        case dock(CmuxNextLayout.DockEdge)
    }

    /// Opens a link dragged out of a chat (``LinkDragItem``) where it was dropped (``LinkDropPlan``)
    /// in `content`: a tab in the pane, or a tab opened there unselected and moved in one daemon
    /// move into the new split, column or dock. False when the target pane is gone or nothing opened.
    @discardableResult
    func drop(_ item: LinkDragItem, plan: LinkDropPlan, in content: WorkspaceContentController) -> Bool {
        let anchor: LayoutPaneID?, destination: Destination?
        switch plan {
        case .tab(let pane):
            anchor = pane; destination = nil
        case .split(let pane, let edge):
            anchor = pane; destination = .split(edge)
        case .column(let screen, let after):
            let columns = content.layoutModel.screens.first { $0.id == screen }?.layout.columns ?? []
            let column = after.flatMap { id in columns.first { $0.id == id } } ?? columns.last { $0.dock == nil }
            anchor = column?.root.panes.last
            destination = .column(after: column.flatMap { content.handles.columns[$0.id] })
        case .dock(let screen, let edge):
            anchor = content.layoutModel.screens.first { $0.id == screen }?.layout.panes.first
            destination = .dock(edge)
        }
        guard let anchor, let pane = content.panes[anchor] else { return false }
        let make: Make = { pane, placed in
            switch item {
            case .web(let url): return pane.newBrowserTab(url: url, background: placed != nil, then: placed)
            case .file(let url): return pane.services.viewers.openFile(url, in: pane, markdown: false, placed: placed)
            }
        }
        guard let destination else { return make(pane, nil) }
        return make(pane) { [weak self, weak pane] surface in
            guard let self, let pane else { return }
            self.move(surface, from: pane, to: destination, focus: true)
        }
    }

    /// Moves the new tab on `surface` out of `source` to `destination` (a new split, column or dock)
    /// once the store lists it, then focuses it unless not `focus`. A failed move selects it where
    /// it is, so it never stays hidden.
    private func move(_ surface: SurfaceID, from source: PaneController, to destination: Destination, focus: Bool) {
        let services = source.services, store = source.daemon.store
        let intent = focus ? source.workspace?.beginFocusIntent() : nil
        services.registry.track(Task { @MainActor [weak source] () -> ActionWorkFailure? in
            let listed = Task { @MainActor () -> TabModel? in
                if let tab = store.tab(surface: surface) { return tab }
                // `tabListRevision`: the tracked read hears the tab appear (AppServices.locateTab).
                for await found in ObservationStream({ _ = store.tabListRevision; return store.tab(surface: surface) != nil }) where found {
                    return store.tab(surface: surface)
                }
                return nil
            }
            let bound = DemandTimer(owner: "LinkOpener.tabListed")
            bound.schedule(after: Self.listLimit) { @MainActor in listed.cancel() }
            let found = await listed.value
            bound.cancel()
            guard let tab = found, let source, let anchor = store.pane(holding: tab) else { return "link open: the new tab did not open" }
            let moved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                switch destination {
                case .besideColumn:
                    let after = AgentBesidePlacement.newColumn(beside: anchor, in: store)
                    TabMoves.toNewColumn(tab, anchor: anchor, afterColumn: after, services: services) { done.resume(returning: $0) }
                case .column(let after):
                    TabMoves.toNewColumn(tab, anchor: anchor, afterColumn: after, services: services) { done.resume(returning: $0) }
                case .split(let edge):
                    TabMoves.toNewSplit(tab, pane: anchor, edge: edge, services: services) { done.resume(returning: $0) }
                case .dock(let edge):
                    TabMoves.toNewDockColumn(tab, anchor: anchor, edge: edge, services: services) { done.resume(returning: $0) }
                }
            }
            let column = if case .besideColumn = destination { true } else { false }
            if moved {
                if let intent { source.workspace?.expectFocus(on: surface, awayFrom: source.paneKey, generation: intent) }
                if column { await AgentBesidePlacement.revealMoved(tab.id, from: anchor, services: services) }
                return nil
            }
            source.select(StripTabID(tab.id))
            if focus { source.focusContent() }
            return "link open: the move to the right failed (see the app log)"
        })
    }
}
