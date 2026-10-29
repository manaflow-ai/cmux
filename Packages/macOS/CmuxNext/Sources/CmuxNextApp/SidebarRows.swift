import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar

/// The one writer of a window's sidebar rows (cx-odqn): the live rows (the
/// store's, with the saved seed) with the pending drag edits applied in
/// order. An edit shows at once and leaves when its commands replied and
/// the home store holds their result (read-your-writes), or when they
/// failed, so no live recompute in between (a row's title or activity, the
/// echo of one step of a several-step placement) shows the old or a
/// partial order. A helper beside SidebarBridge (its type is at its size limit).
@MainActor
final class SidebarRows {
    private let model: SidebarModel
    private var live: [SidebarRowSection] = []
    private var pending = SidebarPendingEdits()
    /// A group's fold the user asked for that the home store has not shown
    /// yet (cx-qno.17): the newest click wins over a live recompute, so a
    /// fast run of clicks toggles once per click.
    private var folds: [GroupID: Fold] = [:]
    private var foldSerial = 0
    /// A fold the sidebar shows before its owner holds it. A personal-state fold leaves when its
    /// command settles; a sidebar-document fold (`untilShown`) leaves once the live rows show it
    /// (its echo rebuilds no rows), or when it is refused.
    private struct Fold {
        var collapsed: Bool
        var serial: Int
        var untilShown = false
    }
    /// Follows the sidebar document's fold-only batches (another client's fold).
    private var foldFollow: Task<Void, Never>?
    /// The rows of creates the daemon has not reported yet, at their slots
    /// over the edits (`PendingWorkspaceRows`), and the home workspace.
    private var creating: (rows: [PendingWorkspaceRows.Row], home: String?) = ([], nil)
    /// The band groups another window lists (`SidebarDocProjection.bandGroupsListedElsewhere`) as last shown:
    /// a move of a workspace to another window changes them with no row of this one (#25776).
    private var elsewhere: Set<String>?
    /// Preview-only App Store rows are kept in the stored document but are
    /// removed from every rendered placement, including machine and group
    /// projections that do not come from `layout.sections`.
    private var showAppStore = true

    #if DEBUG
    /// The rows `debug.sidebar_nested_fixture` shows instead of the live ones (nested-groups prototype captures).
    var fixture: [CmuxNextSidebar.SidebarSection]? {
        didSet { show() }
    }
    #endif

    init(model: SidebarModel) {
        self.model = model
    }

    /// The layout the sidebar draws: the store's without a stored All chats section (cx-n0i9).
    static func visibleLayout(_ document: SidebarLayoutDocument, showAppStore: Bool = true) -> SidebarLayoutDocument {
        var visible = document.withoutChats
        guard !showAppStore else { return visible }
        visible.sections = visible.sections.map { section in
            var section = section
            section.items.removeAll { item in
                item.ref == .builtIn(.appStore) || item.ref == .app(SidebarLayoutDocument.firstPartyApps[.appStore] ?? "cmux/app-store")
            }
            return section
        }
        return visible
    }

    /// The layout window `windowID` draws: `visibleLayout` without the band's
    /// workspaces another window owns, so a new window starts clean. Only on
    /// the sidebar document, whose band moves anchor on a drawn neighbour; the
    /// older owner's index ops count the stored layout; the bridge translates
    /// visible item indexes back to stored indexes before sending edits.
    static func visibleLayout(_ document: SidebarLayoutDocument, window windowID: String, profile: ProfileID? = nil, machines: MachineRegistry,
                              registry: WindowRegistry, showAppStore: Bool = true) -> SidebarLayoutDocument {
        guard SidebarDocWiring.isActive else { return visibleLayout(document, showAppStore: showAppStore) }
        return visibleLayout(document, showAppStore: showAppStore)
            .scopedToWindow(ownedElsewhere: bandHides(window: windowID, profile: profile, machines: machines, registry: registry))
    }

    /// Whether window `windowID`'s band leaves out the workspace item a layout ref value names: another
    /// window owns the workspace, or the window's space `profile` does not show it
    /// (plans/cmux-next/spaces-overhaul-DESIGN.md rule 1: a pin draws only in its own space, so a click on
    /// it never switches the window's space). A closed workspace has no space and stays.
    static func bandHides(window windowID: String, profile: ProfileID?, machines: MachineRegistry,
                          registry: WindowRegistry) -> (String) -> Bool {
        let refs = WorkspaceLayoutRefs(machines: machines)
        let membership = profile == nil ? nil : WindowProfiles.membership(machines)
        return { value in
            if refs.ownedElsewhere(value, window: windowID, registry: registry) { return true }
            guard let profile, let membership, let id = refs.workspaceID(for: .workspace(value)) else { return false }
            return !WindowProfiles.shows(id, profile: profile, machines: machines, membership: membership)
        }
    }

    /// Shows `live` (when given) with the pending edits applied, then the
    /// rows of the creates in flight (`creating`, when given). `unlessShown`: nothing to do when `live` and `creating`
    /// are what the rows show already (patches included), so a structural pass that lists nothing new sets no sections
    /// (sidebar churn: at 400 workspaces each set arranged and compared every row). A changed `elsewhere` shows again.
    func show(_ live: [SidebarRowSection]? = nil, creating: (rows: [PendingWorkspaceRows.Row], home: String?)? = nil, unlessShown: Bool = false,
              elsewhere: Set<String>? = nil, showAppStore: Bool? = nil) {
        let sameVisibility = showAppStore == nil || showAppStore == self.showAppStore
        if let showAppStore { self.showAppStore = showAppStore }
        let sameElsewhere = elsewhere == nil || elsewhere == self.elsewhere
        if let elsewhere { self.elsewhere = elsewhere }
        if unlessShown, let live, let creating, live == self.live, creating == self.creating, sameElsewhere, sameVisibility { return }
        if let live { self.live = live }
        if let creating { self.creating = creating }
        #if DEBUG
        if let fixture { return model.setSections(fixture) }
        #endif
        var sections = PendingWorkspaceRows.adding(self.creating.rows, to: pending.apply(to: self.live), home: self.creating.home)
        for (group, fold) in folds {
            guard let (s, n) = SidebarEdits.locateGroup(group, in: sections), case var .group(shown) = sections[s].nodes[n] else { continue }
            guard shown.isCollapsed != fold.collapsed else {
                if fold.untilShown { folds[group] = nil } // the live rows hold it now
                continue
            }
            shown.isCollapsed = fold.collapsed
            sections[s].nodes[n] = .group(shown)
        }
        // Manual order only (Leo 2026-10-20): a row state shows as a badge; attention order is the Priority view's.
        model.hiddenItemRefs = self.showAppStore ? [] : [.app("cmux/app-store"), .builtIn(.appStore)]
        model.setSections(sections)
    }

    /// Row content of listed workspaces changed (`SidebarRowFeed`): written in place, or shown again when it moves rows.
    func patch(_ changed: [SidebarWorkspace]) {
        live = SidebarSection.patching(changed, in: live)
        #if DEBUG
        if fixture != nil { return }
        #endif
        if !model.patchWorkspaces(changed) { show() }
    }

    /// Folds or opens `group` at once and keeps that look until `body`
    /// replied and the home store holds it, or failed (then `resync`).
    func fold(_ group: GroupID, collapsed: Bool, on home: DaemonService, resync: @escaping @MainActor () -> Void,
              _ body: @escaping DaemonCommandBody) {
        foldSerial += 1
        let serial = foldSerial
        folds[group] = Fold(collapsed: collapsed, serial: serial)
        // The fold shows now, on this group's rows only (no rebuild of every row: state-ownership-DESIGN.md).
        model.setGroupCollapsed(group, collapsed)
        // Settled: the home store holds the fold, and the live rows it maps show it; a failure resyncs.
        let settle: @MainActor () -> Void = { [weak self] in
            guard let self, folds[group]?.serial == serial else { return }
            folds[group] = nil
        }
        let transaction = ClientTransactionID.generate()
        // task-owner: one personal fold command; settles its fold
        Task {
            guard await home.request("update-personal-group", transaction: transaction, { connection, _ in try await body(connection) }) != nil else {
                settle()
                return resync()
            }
            home.whenApplied(transaction, settle)
        }
    }

    /// Folds or opens `group` at once (the sidebar document path) and keeps that look until the
    /// live rows show it, or `refuse` drops it. Costs the group's rows: no row is rebuilt.
    func foldShown(_ group: GroupID, collapsed: Bool) {
        foldSerial += 1
        folds[group] = Fold(collapsed: collapsed, serial: foldSerial, untilShown: true)
        model.setGroupCollapsed(group, collapsed)
    }

    /// The fold of `group` was refused: the live rows show again.
    func dropFold(_ group: GroupID) {
        guard folds.removeValue(forKey: group) != nil else { return }
        show()
    }

    /// Applies the sidebar document's fold-only batches (another client folded a group) to this
    /// window's rows, one group each: `SidebarDocStore.foldRevision`.
    func followFolds(of store: SidebarDocStore) {
        foldFollow?.cancel()
        // task-owner: this window's rows (ends at the first change after they are gone; a second call replaces it);
        // event-driven (Observation)
        foldFollow = Task { [weak self, weak store] in
            for await _ in ObservationStream({ store?.foldRevision }) {
                guard let self, let store else { return }
                for (id, collapsed) in store.lastFolds {
                    let group = GroupID(id)
                    if let held = folds[group] {
                        // This window's own fold came back: the store holds it. Another value is an earlier click's
                        // echo (a later click's comes after it), so the newer look stays.
                        if held.untilShown, held.collapsed == collapsed {
                            folds[group] = nil
                            setLive(group, collapsed: collapsed)
                        }
                        continue
                    }
                    // The store holds it already (the next live rows map it from `groupFolds`): the rows kept
                    // here take it too, so a redraw before them does not show the old fold.
                    setLive(group, collapsed: collapsed)
                    model.setGroupCollapsed(group, collapsed)
                }
            }
        }
    }

    /// Writes `group`'s fold into the live rows kept here (one group, no redraw).
    private func setLive(_ group: GroupID, collapsed: Bool) {
        guard let (s, n) = SidebarEdits.locateGroup(group, in: live), case var .group(shown) = live[s].nodes[n],
              shown.isCollapsed != collapsed else { return }
        shown.isCollapsed = collapsed
        live[s].nodes[n] = .group(shown)
    }

    /// Shows `intent` at once, until `settle`.
    func add(_ intent: SidebarIntent) -> SidebarPendingEdits.Token {
        let edit = pending.add(intent)
        show()
        return edit
    }

    func settle(_ edit: SidebarPendingEdits.Token?) {
        guard let edit else { return }
        pending.settle(edit)
        show()
    }

    /// A command's outcome for `edit`: `failed` settles it and runs `resync`;
    /// `applied` settles it (run once the home store holds the command's result).
    func outcome(_ edit: SidebarPendingEdits.Token?, resync: @escaping @MainActor () -> Void)
        -> (failed: @MainActor () -> Void, applied: (@MainActor () -> Void)?) {
        let failed: @MainActor () -> Void = { [weak self] in
            self?.settle(edit)
            resync()
        }
        guard let edit else { return (failed, nil) }
        return (failed, { [weak self] in self?.settle(edit) })
    }

    /// Sends one personal-state command to `home` for `edit`.
    func send(_ label: String, edit: SidebarPendingEdits.Token?, on home: DaemonService, resync: @escaping @MainActor () -> Void,
              _ body: @escaping DaemonCommandBody) {
        let (failed, applied) = outcome(edit, resync: resync)
        let transaction = ClientTransactionID.generate()
        // task-owner: one personal command; settles its edit
        Task {
            guard await home.request(label, transaction: transaction, { connection, _ in try await body(connection) }) != nil else { return failed() }
            if let applied { home.whenApplied(transaction, applied) }
        }
    }
}
