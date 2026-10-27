import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextFocus
import CmuxNextLayout
import CmuxNextSettings
import CmuxNextWakeups

/// Opens what the person opened from a pane where ``LinkOpenPlacement`` says
/// (`layout.linkPlacement`): every link and path a terminal, an agent chat, Home or a page opens
/// in cmux comes here (``LinkRouter/openInCmux`` for web links, ``openFile(_:from:)`` for files,
/// ``openFolder(_:from:)`` for folders), so no surface picks its own pane.
/// An agent chat that is its screen's main pane (``MainPaneLayout``, `layout.mainPane`) never holds what it opens: that is a
/// tab in the column on its right, or the lone chat docks left to make that column.
///
/// A new tab for the pane on the right opens there, selected and focused. A new split or column is
/// made by opening the tab unselected in the source pane and moving it there in one daemon move
/// (`TabMoves`), the way an agent's tab reaches the column beside its chat (``AgentBesidePlacement``):
/// the source keeps showing what it showed, and its strip never lists the tab (``OutboundTab``).
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
    /// A pane a link's tab gives the focus back to when its close empties its pane (``returnPane(closing:in:emptiesPane:)``).
    private struct Return {
        let pane: LayoutPaneID
        weak var content: WorkspaceContentController?
    }
    /// Each focused tab a click opened outside the pane it was clicked in, by surface: where it was
    /// clicked (a link here, the chat header's Changes, Preview or Files in AgentBesidePlacement).
    private var returns: [SurfaceID: Return] = [:]
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
    /// A source that takes no tabs (Home's pinned dock) finds the pane on its right by the layout's
    /// column order (``LinkOpenPlacement/paneRight(of:columns:takesTabs:recency:)``), not by drawn
    /// frames, which miss a strip column that is scrolled or not laid out yet.
    func target(from source: PaneController, mainPane: Bool = true) -> LinkOpenPlacement<LayoutPaneID>.Target {
        if mainPane, let services, let side = MainPaneLayout.side(from: source, services: services) {
            switch side {
            case .tab(let pane): return .pane(pane)
            case .dockChat: return .dockChat(source.layoutPaneID)
            case .here, .besideDock: break
            }
        }
        let takesTabs = source.stripModel.showsNewTabButton
        let right = source.workspace.flatMap { content -> LayoutPaneID? in
            let takes: (LayoutPaneID) -> Bool = { content.panes[$0]?.stripModel.showsNewTabButton == true }
            if !takesTabs, let screen = content.layoutModel.screen(containing: source.layoutPaneID),
               let found = LinkOpenPlacement<LayoutPaneID>.paneRight(of: source.layoutPaneID,
                                                                     columns: screen.layout.visualColumns.map(\.root.panes),
                                                                     takesTabs: takes, recency: content.recentPanes) {
                return found
            }
            return PaneHandlers.neighbor(of: source.layoutPaneID, direction: .right, in: content).flatMap { takes($0) ? $0 : nil }
        }
        return LinkOpenPlacement(setting: placement()).target(source: source.layoutPaneID, takesTabs: takesTabs, right: right)
    }

    /// Opens through `make` where the rule puts it. `background`: the opened tab takes no focus.
    /// `mainPane` false: main pane layout does not apply (a chat, which belongs in the dock, not
    /// the column on its right). False with no source pane (no window) or when `make` refused.
    @discardableResult
    func open(from source: PaneController?, background: Bool = false, mainPane: Bool = true, _ make: Make) -> Bool {
        guard let source = source ?? services?.windows.active?.focusedPane else { return false }
        switch target(from: source, mainPane: mainPane) {
        case .pane(let id):
            return make(id == source.layoutPaneID ? source : source.workspace?.panes[id] ?? source, nil)
        case .splitRight:
            let outbound = OutboundTab.begin(in: source)
            return outbound.started(make(source) { [weak self, weak source] surface in
                guard let self, let source else { return outbound.finish(moved: false) }
                self.move(surface, from: source, to: .split(.right), focus: !background, outbound: outbound)
            })
        case .newColumn:
            let outbound = OutboundTab.begin(in: source)
            return outbound.started(make(source) { [weak self, weak source] surface in
                guard let self, let source else { return outbound.finish(moved: false) }
                self.move(surface, from: source, to: .besideColumn, focus: !background, outbound: outbound)
            })
        case .besideDock:
            // A lone pinned dock closed to tabs: the daemon makes a tab aimed at it in a new column
            // right of it. Home's dock takes tabs, so the tab is made there and moves to the right.
            guard source.isOpenPinnedDockPane else { return make(source, nil) }
            return make(source) { [weak self, weak source] surface in
                guard let self, let source else { return }
                self.moveBeside(surface, from: source, focus: !background)
            }
        case .dockChat:
            let outbound = OutboundTab.begin(in: source)
            return outbound.started(make(source) { [weak source] surface in
                guard let source else { return outbound.finish(moved: false) }
                outbound.made(surface)
                MainPaneLayout.dockChat(of: source, keeping: surface, focus: !background, services: source.services, outbound: outbound)
            })
        }
    }

    /// A web link in a cmux browser tab (``LinkRouter/openInCmux``), as Chrome opens a clicked
    /// link (Leo 2026-10-21). In the source's own pane the clicked tab is its opener: the new tab
    /// goes right after it and its close selects it again (``BrowserTabOpeners``). A focused tab
    /// anywhere else gives the focus back to the source when its close empties its pane (``returnPane(closing:in:emptiesPane:)``).
    /// `reusesTab` (an agent chat's links and cards): a page the pane on the right already shows is
    /// selected there instead of opened again; a terminal's Cmd-click stays a new, fresh tab.
    @discardableResult
    func openWeb(_ url: URL, from source: PaneController?, background: Bool, reusesTab: Bool = false) -> Bool {
        let from = source ?? services?.windows.active?.focusedPane
        // The person's intent: an agent's open in flight (AgentBesidePlacement) yields to it.
        if !background { _ = from?.workspace?.beginFocusIntent() }
        // The same link clicked again (a chat's PR link or card): the pane on the right selects the
        // tab it already has for that page instead of piling up another (Austin 2026-10-25, eleven
        // tabs of one PR). A tab in the source's own pane stays Chrome's: each click is a new tab.
        if reusesTab, !background, let from, case .pane(let id) = target(from: from), id != from.layoutPaneID,
           let pane = from.workspace?.panes[id], let shown = browserTab(showing: url, in: pane) {
            // As for a new tab clicked open there: its close, emptying that pane, gives the focus back.
            if let content = from.workspace { returnFocus(of: shown.surface, to: from.layoutPaneID, in: content) }
            pane.select(StripTabID(shown.id))
            pane.focusContent()
            return true
        }
        return open(from: from, background: background) { [weak self, weak from] pane, placed in
            let here = pane === from && placed == nil
            let opener = here ? from?.selectedTab?.surface : nil
            let back = background || here ? nil : from
            var then = placed
            if back != nil {
                then = { @MainActor [weak self, weak back] surface in
                    if let back, let content = back.workspace { self?.returnFocus(of: surface, to: back.layoutPaneID, in: content) }
                    placed?(surface)
                }
            }
            return pane.newBrowserTab(url: url, background: background || placed != nil, opener: opener, then: then)
        }
    }

    /// A browser tab of `pane` showing `url`'s page (``SidebarBridge/samePage(_:_:)``) at the same
    /// fragment, so a link to a comment still opens at it: the live page first, else the daemon's record.
    func browserTab(showing url: URL, in pane: PaneController) -> TabModel? {
        pane.pane.tabs.first { tab in
            guard tab.kind == .browser, !ProvisionalTab.isProvisional(tab.id),
                  let shown = services?.cache.existingBrowser(tab.id)?.tab.state.url ?? tab.url.flatMap(URL.init(string:)) else { return false }
            return SidebarBridge.samePage(shown, url) && shown.fragment == url.fragment
        }
    }

    /// Records that closing `surface`'s tab gives the focus back to pane `pane` of `content`.
    func returnFocus(of surface: SurfaceID, to pane: LayoutPaneID, in content: WorkspaceContentController) {
        returns = returns.filter { $0.value.content != nil }
        returns[surface] = Return(pane: pane, content: content)
    }

    /// The pane tab `id` of `pane` gives the focus back to as it closes: the pane it was clicked
    /// open from (``returnFocus(of:to:in:)``), when the close empties `pane` (`emptiesPane`, so the
    /// pane goes away with it), `pane` has the focus and that pane still shows in the same
    /// workspace. Nil otherwise. The record is spent either way.
    /// While `pane` has other tabs the focus stays in it, on the tab the close selects: Leo
    /// 2026-10-21, "when i close a tab in the browser then it refocuses immediately back to the
    /// agent pane", so his next Cmd-W closed the agent chat instead of the next browser tab.
    func returnPane(closing id: StripTabID, in pane: PaneController, emptiesPane: Bool) -> PaneController? {
        returns = returns.filter { $0.value.content != nil }
        guard let surface = pane.tab(id)?.surface, let back = returns.removeValue(forKey: surface), emptiesPane,
              let content = pane.workspace, back.content === content, back.pane != pane.layoutPaneID,
              content.focusedPane === pane else { return nil }
        return content.panes[back.pane]
    }

    /// A file: the Markdown page, the code editor or the browser tab's preview (``FilePageOpener``).
    /// A tab that already shows the file is selected where it is. False when it did not open (the
    /// refusal shows). `position` (a Find result): the code editor opens with the cursor there.
    @discardableResult
    /// `asText` (Open as Text, u9489): a page cmux renders (Markdown, HTML, SVG) opens as its source
    /// in the code editor, placed as any open is.
    func openFile(_ file: URL, from source: PaneController?, markdown: Bool = false, asText: Bool = false,
                  at position: FilePosition? = nil) -> Bool {
        open(from: source) { pane, placed in
            pane.services.viewers.openFile(file, in: pane, markdown: markdown, asText: asText, at: position, placed: placed)
        }
    }

    /// A file of `machine` (#25581, a Cloud workspace's path): its page, read from that machine,
    /// placed as ``openFile(_:from:markdown:asText:at:)`` places a file of this Mac.
    @discardableResult
    func openFile(_ file: URL, on machine: DaemonService, from source: PaneController?, at position: FilePosition? = nil) -> Bool {
        open(from: source) { pane, placed in
            pane.services.viewers.openFile(file, on: machine, in: pane, at: position, placed: placed)
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
        case .dockChat:
            // The chat docks and leaves the folder's terminal in its pane, in one daemon commit.
            let spawn = SpawnOptions(cwd: path, workspace: source.workspace?.workspace.key)
            ChatColumnPlacement.route(from: source, respawn: .terminal(spawn), services: source.services)?.newTerminalTab(cwd: path)
        case .splitRight, .newColumn:
            var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: source.paneKey),
                                              arguments: ["cwd": .string(path)], origin: .user)
            invocation.opensTerminal = true
            source.services.registry.perform("splitRight", invocation: invocation)
        }
    }

    /// Where ``move(_:from:to:focus:outbound:)`` takes a new tab.
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
        let outbound = OutboundTab.begin(in: pane)
        return outbound.started(make(pane) { [weak self, weak pane] surface in
            guard let self, let pane else { return outbound.finish(moved: false) }
            self.move(surface, from: pane, to: destination, focus: true, outbound: outbound)
        })
    }

    /// Moves new tab `surface`, made in `source`, to a new column right of it, focusing `target` in
    /// it when `focus` (Home's dock, which takes tabs, opens its tools beside itself this way).
    func moveBeside(_ surface: SurfaceID, from source: PaneController, focus: Bool, target: FocusState.Target = .content) {
        move(surface, from: source, to: .besideColumn, focus: focus, target: target)
    }

    /// Moves the new tab on `surface` out of `source` to `destination` (a new split, column or dock)
    /// once the store lists it, then focuses it unless not `focus`. Until then `source`'s strip leaves it
    /// out when `outbound` is supplied. A failed move selects it where it is, so it never stays hidden.
    private func move(_ surface: SurfaceID, from source: PaneController, to destination: Destination, focus: Bool,
                      target: FocusState.Target = .content, outbound: OutboundTab? = nil) {
        outbound?.made(surface)
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
            guard let tab = found, let source, let anchor = store.pane(holding: tab) else {
                outbound?.finish(moved: false)
                return "link open: the new tab did not open"
            }
            // An open in the background keeps the focus where it is: the daemon's move would focus the tab.
            let keepFocus = !focus
            let moved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                switch destination {
                case .besideColumn:
                    let after = AgentBesidePlacement.newColumn(beside: anchor, in: store)
                    TabMoves.toNewColumn(tab, anchor: anchor, afterColumn: after, services: services, keepFocus: keepFocus) { done.resume(returning: $0) }
                case .column(let after):
                    TabMoves.toNewColumn(tab, anchor: anchor, afterColumn: after, services: services, keepFocus: keepFocus) { done.resume(returning: $0) }
                case .split(let edge):
                    TabMoves.toNewSplit(tab, pane: anchor, edge: edge, services: services, keepFocus: keepFocus) { done.resume(returning: $0) }
                case .dock(let edge):
                    TabMoves.toNewDockColumn(tab, anchor: anchor, edge: edge, services: services) { done.resume(returning: $0) }
                }
            }
            let column = if case .besideColumn = destination { true } else { false }
            outbound?.finish(moved: moved)
            if moved {
                if let intent { source.workspace?.expectFocus(on: surface, target: target, awayFrom: source.paneKey, generation: intent) }
                if column { await AgentBesidePlacement.revealMoved(tab.id, from: anchor, services: services) }
                return nil
            }
            source.select(StripTabID(tab.id))
            if focus { source.focusContent() }
            return "link open: the move to the right failed (see the app log)"
        })
    }
}
