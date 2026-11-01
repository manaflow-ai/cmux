import AppKit
import CmuxNextActions
import CmuxNextAgentPane
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
    /// Every open on the right of a pane takes its turn here, one at a time per source pane, with
    /// ``AgentTabStore/openOnRight(of:origin:open:created:finished:)``'s (``RightColumnTurns``).
    let turns = RightColumnTurns()
    /// Set by an open's `make` that showed an existing tab instead of making one, read right after it
    /// returns (``moved(from:to:background:_:done:)``): synchronous, one open at a time.
    private var shownInPlace = false

    /// Called by a `make` that was given `placed` but showed a tab already there instead of making one.
    func openedInPlace() { shownInPlace = true }

    init(services: AppServices) {
        self.services = services
        placement = { [weak services] in services?.settings?.snapshot.linkPlacement ?? .fallback }
    }

    /// The pane a link opened from tab `key` (a tab id or resource id) starts from: the pane
    /// showing that tab, else the active window's focused pane.
    func source(tab key: String?) -> PaneController? {
        guard let services else { return nil }
        if let key, let (_, pane) = services.locateTabOnAnyMachine(key), let controller = services.paneController(for: pane) { return controller }
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
    /// `kind`: what opens, a terminal or a browser, which goes to a right-column pane already holding
    /// that kind (``RightColumnPlacement``); nil for anything else.
    func target(from source: PaneController, mainPane: Bool = true, besideChat: Bool = false, kind: RightColumnPlacement.Kind? = nil) -> LinkOpenPlacement<LayoutPaneID>.Target {
        let content = source.workspace
        let width: (LayoutPaneID) -> CGFloat? = { content?.panes[$0].flatMap(Self.width(of:)) }
        let holds: (LayoutPaneID, RightColumnPlacement.Kind) -> Bool = { id, kind in content?.panes[id].map { Self.holds($0, kind) } ?? false }
        if let services, let side = besideChat ? ChatColumnPlacement.resolve(from: source, services: services)
            : (mainPane ? MainPaneLayout.side(from: source, services: services) : nil) {
            switch side {
            case .tab(let pane):
                // The strip column right of the docked chat is its right side: the same lower split (ux-owner 2026-10-30).
                let column = content.map { Self.rightPanes(beside: source.layoutPaneID, in: $0) } ?? []
                return LinkOpenPlacement<LayoutPaneID>.inColumn(right: pane, column: column, sourceWidth: Self.width(of: source), width: width,
                                                                kind: kind, holds: holds)
            case .dockChat: return .dockChat(source.layoutPaneID)
            case .here, .besideDock: break
            }
        }
        let takesTabs = source.stripModel.showsNewTabButton
        var column: [LayoutPaneID] = []
        let right = source.workspace.flatMap { content -> LayoutPaneID? in
            let takes: (LayoutPaneID) -> Bool = { content.panes[$0]?.stripModel.showsNewTabButton == true }
            if !takesTabs, let screen = content.layoutModel.screen(containing: source.layoutPaneID),
               let found = LinkOpenPlacement<LayoutPaneID>.paneRight(of: source.layoutPaneID,
                                                                     columns: screen.layout.visualColumns.map(\.root.panes),
                                                                     takesTabs: takes, recency: content.recentPanes) {
                return found
            }
            // The right column beside the source (RightColumnPlacement): a split below its one pane, else its lower pane.
            column = Self.rightPanes(beside: source.layoutPaneID, in: content)
            // `right` and `column` read the same screen's frames; should the neighbour rule still find none
            // (recency, a pane that takes no tabs), the measured column's top pane is the right side, so an
            // occupied column never reads as empty and splits right again (review of #28044 at 1cfd9d14).
            return PaneHandlers.neighbor(of: source.layoutPaneID, direction: .right, in: content).flatMap { takes($0) ? $0 : nil } ?? column.first
        }
        return LinkOpenPlacement(setting: besideChat ? .splitRight : placement()).target(source: source.layoutPaneID, takesTabs: takesTabs, right: right, column: column,
                                                              sourceWidth: Self.width(of: source), width: width, kind: kind, holds: holds)
    }

    /// Opens through `make` where the rule puts it. `background`: the opened tab takes no focus.
    /// `mainPane` false: main pane layout does not apply (a chat, which belongs in the dock, not
    /// the column on its right). False with no source pane (no window) or when `make` refused.
    /// Opens beside one source run one at a time (``turns``): one asked for
    /// while another is still moving into place waits, answers true, and decides its place once that
    /// one has landed, from the column it made.
    @discardableResult
    func open(from source: PaneController?, background: Bool = false, mainPane: Bool = true, besideChat: Bool = false, kind: RightColumnPlacement.Kind? = nil,
              focusing focus: FocusState.Target = .content, _ make: @escaping Make) -> Bool {
        guard let source = source ?? services?.windows.active?.focusedPane else { return false }
        var opened = true
        let now = turns.serially(beside: source.layoutPaneID) { [weak self, weak source] done in
            guard let self, let source else { return done() }
            opened = self.place(from: source, background: background, mainPane: mainPane, besideChat: besideChat, kind: kind, focusing: focus, make, done: done)
        }
        return now ? opened : true
    }

    /// ``open(from:background:mainPane:_:)`` in its turn: `done` runs once the open has landed or
    /// failed, so the next open beside `source` reads the column it left.
    private func place(from source: PaneController, background: Bool, mainPane: Bool, besideChat: Bool, kind: RightColumnPlacement.Kind?, focusing focus: FocusState.Target, _ make: Make,
                       done: @escaping @MainActor () -> Void) -> Bool {
        switch target(from: source, mainPane: mainPane, besideChat: besideChat, kind: kind) {
        case .pane(let id):
            defer { done() }
            return make(id == source.layoutPaneID ? source : source.workspace?.panes[id] ?? source, nil)
        case .splitRight:
            return moved(from: source, to: .split(.right), background: background, focusing: focus, make, done: done)
        case .splitBelow(let id):
            // Made unselected in the pane on the right, which keeps showing what it shows, then moved below it.
            guard let right = source.workspace?.panes[id] else { defer { done() }; return make(source, nil) }
            return moved(from: right, to: .split(.bottom), background: background, focusing: focus, make, done: done)
        case .newColumn:
            return moved(from: source, to: .besideColumn, background: background, focusing: focus, make, done: done)
        case .besideDock:
            // A lone pinned dock closed to tabs: the daemon makes a tab aimed at it in a new column
            // right of it. Home's dock takes tabs, so the tab is made there and moves to the right,
            // left out of the dock's strip on the way (``OutboundTab``): it first shows on the right.
            guard source.isOpenPinnedDockPane else { defer { done() }; return make(source, nil) }
            let outbound = OutboundTab.begin(in: source)
            shownInPlace = false
            let made = outbound.started(make(source) { [weak self, weak source] surface in
                guard let self, let source else { done(); return outbound.finish(moved: false) }
                self.moveBeside(surface, from: source, focus: !background, outbound: outbound, then: done)
            })
            return ended(made, outbound, done)
        case .dockChat:
            let outbound = OutboundTab.begin(in: source)
            shownInPlace = false
            let made = outbound.started(make(source) { [weak source] surface in
                guard let source else { done(); return outbound.finish(moved: false) }
                outbound.made(surface)
                MainPaneLayout.dockChat(of: source, keeping: surface, focus: !background, services: source.services, outbound: outbound) { _ in done() }
            })
            return ended(made, outbound, done)
        }
    }

    /// After an open's `make`: a refusal, or a tab shown where it already was (``shownInPlace``), moves
    /// nothing, so its turn ends now; else the move ends it.
    private func ended(_ made: Bool, _ outbound: OutboundTab, _ done: @MainActor () -> Void) -> Bool {
        if made, shownInPlace {
            shownInPlace = false
            outbound.finish(moved: false)
        } else if made {
            return true
        }
        done()
        return made
    }

    /// `make`'s tab, made unselected in `pane` and kept out of its strip (``OutboundTab``), moved to
    /// `destination`; `done` once the move has landed or failed.
    private func moved(from pane: PaneController, to destination: Destination, background: Bool, focusing focus: FocusState.Target = .content, _ make: Make,
                       done: @escaping @MainActor () -> Void) -> Bool {
        let outbound = OutboundTab.begin(in: pane)
        shownInPlace = false
        let made = outbound.started(make(pane) { [weak self, weak pane] surface in
            guard let self, let pane else { done(); return outbound.finish(moved: false) }
            self.move(surface, from: pane, to: destination, focus: !background, target: focus, outbound: outbound, then: done)
        })
        return ended(made, outbound, done)
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
        // tabs of one PR). Any pane of the right column counts, not only the one this open would use
        // (LinkOpenPlacement.reusePanes). A tab in the source's own pane stays Chrome's: each click is a new tab.
        if reusesTab, !background, let from, let content = from.workspace,
           let found = LinkOpenPlacement<LayoutPaneID>.reusePanes(target: target(from: from, kind: .browser), column: Self.rightPanes(beside: from.layoutPaneID, in: content),
                                                                  source: from.layoutPaneID)
               .lazy.compactMap({ id in content.panes[id].flatMap { pane in self.browserTab(showing: url, in: pane).map { (pane: pane, tab: $0) } } }).first {
            let (pane, shown) = (found.pane, found.tab)
            // As for a new tab clicked open there: its close, emptying that pane, gives the focus back.
            returnFocus(of: shown.surface, to: from.layoutPaneID, in: content)
            pane.select(StripTabID(shown.id))
            pane.focusContent()
            return true
        }
        return open(from: from, background: background, kind: .browser) { [weak self, weak from] pane, placed in
            let here = pane === from && placed == nil
            // A pane-local tab keeps Chrome's opener relationship. When placement moves the new
            // tab into another pane, the source pane must not claim it as a child; the placement
            // callback owns focus and insertion for that destination.
            let opener = here ? pane.selectedTab?.surface : nil
            let back = background || here ? nil : from
            var then = placed
            if back != nil {
                then = { @MainActor [weak self, weak back] surface in
                    if let back, let content = back.workspace { self?.returnFocus(of: surface, to: back.layoutPaneID, in: content) }
                    placed?(surface)
                }
            }
            return pane.newBrowserTab(url: url, background: background || placed != nil, opener: opener, placementOwner: placed != nil, then: then)
        }
    }

    /// The existing pane a target opens in, or below (a lower split): nil for a new split, column or dock move.
    static func existingPane(of target: LinkOpenPlacement<LayoutPaneID>.Target) -> LayoutPaneID? {
        switch target {
        case .pane(let id), .splitBelow(of: let id): id
        default: nil
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
    /// `machine`: the file lives on that machine; nil or the local daemon opens this Mac’s file.
    @discardableResult
    /// `asText` (Open as Text, u9489): a page cmux renders (Markdown, HTML, SVG) opens as its source
    /// in the code editor, placed as any open is.
    func openFile(_ file: URL, on machine: DaemonService? = nil, from source: PaneController?, markdown: Bool = false, asText: Bool = false,
                  at position: FilePosition? = nil) -> Bool {
        open(from: source) { [weak self] pane, placed in
            // A tab that already shows the file is selected where it is and never reports to `placed`:
            // it says so, so its turn ends now (review of the #28044 carry at 1eb458cf).
            var inPlace: (@MainActor () -> Void)?
            if placed != nil { inPlace = { self?.openedInPlace() } }
            if let machine, !machine.isLocal {
                return pane.services.viewers.openFile(file, on: machine, in: pane, asText: asText, at: position, placed: placed,
                                                      shownInPlace: inPlace)
            }
            return pane.services.viewers.openFile(file, in: pane, markdown: markdown, asText: asText, at: position, placed: placed,
                                                  shownInPlace: inPlace)
        }
    }

    /// A folder: a terminal there. In a new split it is the split's own terminal (Split Right with
    /// that folder); a column or the pane on the right gets a terminal tab.
    func openFolder(_ path: String, from source: PaneController?) {
        guard let source = source ?? services?.windows.active?.focusedPane else { return }
        // In its turn beside `source`, like every open on the right (RightColumnTurns). A split's
        // terminal is made in the pane it splits and moved there, as a New Tab page's terminal is.
        turns.serially(beside: source.layoutPaneID) { [weak self, weak source] done in
            guard let self, let source else { return done() }
            let terminal: Make = { pane, placed in
                // The move owns selection, so the terminal never shows in the source first (as a link's browser tab).
                pane.newTerminalTab(cwd: path, placementOwner: placed != nil, then: placed)
                return true
            }
            switch self.target(from: source, kind: .terminal) {
            case .pane(let id):
                (source.workspace?.panes[id] ?? source).newTerminalTab(cwd: path)
                done()
            case .besideDock:
                source.workspace?.newColumn(after: source.layoutPaneID, options: SpawnOptions(cwd: path, workspace: source.workspace?.workspace.key))
                done()
            case .dockChat:
                // The chat docks and leaves the folder's terminal in its pane, in one daemon commit.
                let spawn = SpawnOptions(cwd: path, workspace: source.workspace?.workspace.key)
                ChatColumnPlacement.route(from: source, respawn: .terminal(spawn), services: source.services)?.newTerminalTab(cwd: path)
                done()
            case .splitRight, .newColumn:
                // A split on the source's right, for New Column too, as Split Right with that folder made it.
                _ = self.moved(from: source, to: .split(.right), background: false, terminal, done: done)
            case .splitBelow(let id):
                // The pane on the right keeps what it shows: the folder's terminal is a split below it.
                _ = self.moved(from: source.workspace?.panes[id] ?? source, to: .split(.bottom), background: false, terminal, done: done)
            }
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
            case .web(let url): return pane.newBrowserTab(url: url, background: placed != nil,
                                                          placementOwner: placed != nil, then: placed)
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
    /// `outbound`, begun before the tab was made, keeps it out of `source`'s strip until it has moved.
    /// `then` runs once the move has landed or failed.
    func moveBeside(_ surface: SurfaceID, from source: PaneController, focus: Bool, target: FocusState.Target = .content,
                    outbound: OutboundTab? = nil, then: (@MainActor () -> Void)? = nil) {
        move(surface, from: source, to: .besideColumn, focus: focus, target: target, outbound: outbound, then: then)
    }

    /// Moves the new tab on `surface` out of `source` to `destination` (a new split, column or dock)
    /// once the store lists it, then focuses it unless not `focus`. Until then `source`'s strip leaves it
    /// out when `outbound` is supplied. A failed move selects it where it is, so it never stays hidden.
    /// `then` runs once the move has landed or failed.
    private func move(_ surface: SurfaceID, from source: PaneController, to destination: Destination, focus: Bool,
                      target: FocusState.Target = .content, outbound: OutboundTab? = nil, then: (@MainActor () -> Void)? = nil) {
        outbound?.made(surface)
        let services = source.services, store = source.daemon.store
        let intent = focus ? source.workspace?.beginFocusIntent() : nil
        let window = source.view.window
        let input = services.keyRouter.creationInputCoordinator
        let keys = focus ? input.continueCreation(in: window, generation: intent) : nil
        if keys != nil, let intent {
            // The source still holds the tab: only the destination may satisfy this focus request.
            source.workspace?.expectFocus(on: surface, target: target, awayFrom: source.paneKey, generation: intent)
        }
        services.registry.track(Task { @MainActor [weak source] () -> ActionWorkFailure? in
            var landed = false
            defer { input.resolve(keys, landed: landed, in: window); then?() }
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
                    let after = store.scrollingColumn(holding: anchor)
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
                landed = true
                return nil
            }
            source.select(StripTabID(tab.id))
            if focus { source.focusContent() }
            landed = focus
            return "link open: the move to the right failed (see the app log)"
        })
    }
}

/// The right column beside a pane as the window shows it, for ``RightColumnPlacement``: the panes
/// that start at its right edge and overlap its height, top to bottom. Only panes that take new
/// tabs count. Every open on the right of a pane takes its turn in ``LinkOpener/turns``.
extension LinkOpener {
    /// The right column beside `source`, measured: its panes (layout pane ids) and their widths.
    static func rightColumn(beside source: PaneController) -> RightColumnPlacement.Column {
        guard let content = source.workspace else { return .init(sourceWidth: width(of: source)) }
        let panes = rightPanes(beside: source.layoutPaneID, in: content)
        var widths: [String: CGFloat] = [:], kinds: [String: Set<RightColumnPlacement.Kind>] = [:]
        for pane in panes {
            widths[pane.rawValue] = content.panes[pane].flatMap(width(of:))
            kinds[pane.rawValue] = content.panes[pane].map { pane in Set([.terminal, .browser].filter { holds(pane, $0) }) }
        }
        return .init(sourceWidth: width(of: source), panes: panes.map(\.rawValue), widths: widths, kinds: kinds)
    }

    /// Whether `pane` holds a tab of `kind`: a local or remote terminal, or a browser tab.
    static func holds(_ pane: PaneController, _ kind: RightColumnPlacement.Kind) -> Bool {
        pane.pane.tabs.contains { tab in
            switch (kind, tab.kind) {
            case (.terminal, .pty), (.terminal, .remoteTerminal), (.browser, .browser): true
            default: false
            }
        }
    }

    /// `pane`'s width once its layout lands (``LayoutRootView/restingContentWidth(of:)``), what every open on the
    /// right reads (links, and agent opens through ``rightColumn(beside:)``). Not its view's bounds: right after a
    /// split the source still shows its old width and the new pane a sliver, so a link opened at once in a narrow
    /// window split below the pane on the right instead of a tab in it (review of #29787 at 29861047). Nil for a
    /// pane its workspace has not laid out (its view's 400 pt placeholder is no measure, so it sets no floor:
    /// fleet runs of #28044 at 8e520360 and caf8e69e, SideOpenStripTests' windowless pane opened links in place).
    static func width(of pane: PaneController) -> CGFloat? {
        pane.workspace?.layoutView.restingContentWidth(of: pane.layoutPaneID)
    }

    /// The panes right of `source` in `content`, top to bottom, from the pane frames of the screen
    /// that holds `source`, active or not (``RightColumnPlacement/column(beside:frames:gap:)``),
    /// keeping those that take new tabs. Review of #28044 at bd2b918d: the active screen's frames
    /// read an empty column for a chat on a screen the person switched away from mid-open.
    static func rightPanes(beside source: LayoutPaneID, in content: WorkspaceContentController) -> [LayoutPaneID] {
        RightColumnPlacement.column(beside: source, frames: content.layoutView.navigationFrames(ofScreenContaining: source))
            .filter { content.panes[$0]?.stripModel.showsNewTabButton == true }
    }
}
