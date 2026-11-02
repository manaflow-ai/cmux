import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
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
    private let document: @MainActor () -> SidebarDocStore?
    private var live: [SidebarRowSection] = []
    /// The sidebar document's `shownChanges` `live` was built at (nil: not from its projection): the creates'
    /// rows that wait for the window's current row wait while `live` is a projection behind (`layoutCatchingUp`).
    private var liveShownAt: UInt64?
    lazy var edits = SidebarRowEdits(model: model, redraw: { [weak self] in self?.show() },
                                             confirmedFold: { [weak self] in self?.setLive($0, collapsed: $1) })
    /// The rows of creates the daemon has not reported yet, at their slots
    /// over the edits (`PendingWorkspaceRows`), and the home workspace.
    private var creating: (rows: [PendingWorkspaceRows.Row], home: String?) = ([], nil)
    /// The band groups this window leaves out (`SidebarDocProjection.bandGroupsNotListedHere`) as last shown:
    /// a move of a workspace to another window changes them with no row of this one (#25776), a space switch too.
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

    /// `document`: the app's own sidebar document store (nil before it starts).
    init(model: SidebarModel, document: @escaping @MainActor () -> SidebarDocStore?) {
        self.model = model
        self.document = document
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

    /// The layout `window` draws, the model's (the one rule: its tests compare with it): `visibleLayout` (App Store
    /// only under Preview Features) without the band's workspaces another window owns or its space hides, nor another
    /// space's groups and Pinned items (`room`): a new window starts clean. Only on the sidebar document, whose band
    /// moves anchor on a drawn neighbour; the older owner's index ops count the stored layout; the bridge maps back.
    static func visibleLayout(_ services: AppServices, window: WindowState) -> SidebarLayoutDocument {
        let visible = visibleLayout(services.sidebarLayout.document, showAppStore: services.settings?.snapshot.previewFeatures == true)
        guard services.sidebarDoc.isActive else { return visible }
        return visible.scopedToWindow(ownedElsewhere: bandHides(window: window.id, profile: window.profileID, machines: services.machines,
                                                                 registry: services.windows.registry.value),
                                      room: window.profileID.rawValue, spaces: services.sidebarDoc.spaces)
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
    /// `shownAt`: the sidebar document's `shownChanges` `live` was built at; a newer one with creates in flight shows
    /// again, since a create waiting for the current row may draw now.
    func show(_ live: [SidebarRowSection]? = nil, shownAt: UInt64? = nil, creating: (rows: [PendingWorkspaceRows.Row], home: String?)? = nil,
              unlessShown: Bool = false, elsewhere: Set<String>? = nil, showAppStore: Bool? = nil) {
        let sameVisibility = showAppStore == nil || showAppStore == self.showAppStore
        if let showAppStore { self.showAppStore = showAppStore }
        let sameElsewhere = elsewhere == nil || elsewhere == self.elsewhere
        if let elsewhere { self.elsewhere = elsewhere }
        let reprojected = live != nil && shownAt != liveShownAt && !(creating ?? self.creating).rows.isEmpty
        if live != nil { liveShownAt = shownAt }
        if unlessShown, !reprojected, let live, let creating, live == self.live, creating == self.creating, sameElsewhere, sameVisibility { return }
        if let live { self.live = live }
        if let creating { self.creating = creating }
        #if DEBUG
        if let fixture { return model.setSections(fixture) }
        #endif
        var sections = PendingWorkspaceRows.adding(self.creating.rows, to: edits.applying(to: self.live), home: self.creating.home,
                                                   catchingUp: layoutCatchingUp)
        edits.applyFolds(to: &sections)
        // Manual order only (Leo 2026-10-20): a row state shows as a badge; attention order is the Priority view's.
        model.hiddenItemRefs = self.showAppStore ? [] : [.app("cmux/app-store"), .builtIn(.appStore)]
        model.setSections(sections)
    }

    /// The live rows are a projection behind the sidebar document (`NewWorkspaceDefaultSlot.layoutCatchingUp`).
    var layoutCatchingUp: Bool { NewWorkspaceDefaultSlot.layoutCatchingUp(document(), rowsAt: liveShownAt) }

    /// Row content of listed workspaces changed (`SidebarRowFeed`): written in place, or shown again when it moves rows.
    func patch(_ changed: [SidebarWorkspace]) {
        live = SidebarSection.patching(changed, in: live)
        #if DEBUG
        if fixture != nil { return }
        #endif
        if !model.patchWorkspaces(changed) { show() }
    }

    /// Folds or opens `group` at once and keeps that look until `body`
    /// replied and the home store holds it, or failed (then `failed`).
    func fold(_ group: GroupID, collapsed: Bool, on home: DaemonService, failed: @escaping @MainActor (ActionWorkFailure) -> Void,
              _ body: @escaping DaemonCommandBody) {
        let settle = edits.fold(group, collapsed: collapsed)
        let transaction = ClientTransactionID.generate()
        // task-owner: one personal fold command; settles its fold
        Task {
            if let failure = await home.failure("update-personal-group", body) {
                settle()
                return failed(failure)
            }
            home.whenApplied(transaction, settle)
        }
    }

    /// Writes `group`'s fold into the live rows kept here (one group, no redraw).
    private func setLive(_ group: GroupID, collapsed: Bool) {
        guard let (s, n) = SidebarEdits.locateGroup(group, in: live), case var .group(shown) = live[s].nodes[n],
              shown.isCollapsed != collapsed else { return }
        shown.isCollapsed = collapsed
        live[s].nodes[n] = .group(shown)
    }

    /// Sends `commands` for `edit`, each to its own daemon and each on its own (a slow or failed one never holds
    /// back the others, which were already told their workspaces close): the edit settles once every one replied and
    /// its daemon's store holds the result (read-your-writes), or at the first failure, which runs `failed` once.
    func send(_ edit: SidebarPendingEdits.Token?, _ commands: [(label: String, daemon: DaemonService, body: DaemonCommandBody)],
              failed onFailure: @escaping @MainActor (ActionWorkFailure) -> Void) {
        let (failed, applied) = edits.outcome(edit, failed: onFailure)
        guard !commands.isEmpty else {
            applied?()
            return
        }
        let replies = SidebarReplies(commands.count, failed: failed, applied: applied)
        for command in commands {
            // task-owner: one sidebar command; reports to the change's `Replies`
            Task {
                if let failure = await command.daemon.failure(command.label, command.body) { return replies.failed(failure) }
                // Its daemon's store holds it once that daemon's events up to the reply are applied.
                command.daemon.whenApplied(.generate(), replies.applied)
            }
        }
    }

    /// Sends one personal-state command to `home` for `edit`.
    func send(_ label: String, edit: SidebarPendingEdits.Token?, on home: DaemonService,
              failed: @escaping @MainActor (ActionWorkFailure) -> Void, _ body: @escaping DaemonCommandBody) {
        send(edit, [(label, home, body)], failed: failed)
    }
}
