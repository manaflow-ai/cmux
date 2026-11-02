#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// SPEC 11.1: the Workspaces tab, an inbox ordered by what needs the user.
///
/// - **Needs You** (only when not empty), then **Recent** (newest activity
///   first), then one folded line per offline Mac that expands in place.
/// - Two-line rows, Mail style: the name and its time, then the status in
///   words naming the agent and its task ("Claude is waiting · Refactor
///   transport layer"), or the branch when idle. A leading gutter holds a
///   warning disc, a spinner or a dot.
/// - The Mac filter is a toolbar menu, remembered per team (`MacFilter`).
///   The navigation subtitle says what is filtered or how many need you.
/// - A tap opens the last tab used here (else the Mac's active tab); a
///   needs-you workspace opens on its waiting tab. Hold a row for its tabs,
///   Rename and Close; swipe left for Close and Rename.
public struct WorkspacesList: View {
    let store: AppStore
    let creator: WorkspaceCreator
    /// Pushes a workspace (the new one, right after a tap).
    let open: (Workspace) -> Void
    /// The signed-in account, for "sign in as …" in the empty state.
    var accountEmail: String?
    /// Links a Mac (live only): a Mac whose list the phone does not have.
    var reconnect: ((String) -> Void)?
    /// Moves the link to a Mac (live only; nothing when it is already the
    /// link's Mac). Called whenever the list is filtered to an online Mac or
    /// one of its workspaces opens (`MacScope.macToLink`).
    var linking: MacLinking?
    /// Pull to refresh (live only).
    var refresh: (() async -> Void)?
    /// Moves to another team (the empty state offers the team where a Mac is).
    var switchTeam: ((String) -> Void)?
    /// Opens Settings → Account (the empty state, when no Mac uses this account).
    var openAccount: (() -> Void)?
    @State private var filter: MacFilter
    /// Reloads the failed team/Mac discovery, not just already-connected workspaces.
    var retryLoad: (() async -> Void)?
    @State private var query = ""
    /// Offline Macs whose rows are unfolded (this session).
    @State private var unfolded: Set<String> = []
    /// A refresh has taken long enough to say so.
    @State private var showsUpdating = false
    /// The offline workspace whose tap is being explained.
    @State private var unavailable: Workspace?
    @State private var renaming: Workspace?
    @State private var renameText = ""
    @State private var closing: Workspace?
    /// Close Other / Above / Below: what was chosen, on which workspace, and what it closes.
    @State private var bulkClosing: BulkClose?
    /// Set Icon… › Emoji…: the workspace and the typed emoji.
    @State private var iconEmoji: Workspace?
    @State private var emojiText = ""
    /// Move Workspace to New Group: the workspace; Rename Group… and Delete
    /// Group: the group. One name field for both.
    @State private var newGroupFor: Workspace?
    @State private var renamingGroup: GroupTarget?
    @State private var deletingGroup: GroupTarget?
    @State private var groupNameText = ""
    /// The rows' status gutter (32 pt at Large): the separators, section
    /// titles, group titles and Mac lines start after it, at the text column.
    @Environment(\.dynamicTypeSize) private var typeSize
    private var gutter: CGFloat { CmuxMobileListColumn.plain(typeSize).text }
    /// Scrolls the UIKit list and reads its visible area (unfolding scrolls
    /// when the first new row would open below it).
    @State private var listControl = WorkspacesListControl()
    /// Each row's frame in the list (read on demand, never drawn from).
    @State var rowFrames = RowFrames()
    /// The inbox, built once per change of what it reads.
    @State private var inboxMemo = WorkspaceInbox.Memo()
    /// The Macs' names and Filter rows, memoized (verify/perf-latency.md).
    @State private var macText = MacFilterMemo()
    @State private var closingFrame: CGRect = .zero

    public init(store: AppStore, creator: WorkspaceCreator, accountEmail: String? = nil,
                reconnect: ((String) -> Void)? = nil, linking: MacLinking? = nil,
                refresh: (() async -> Void)? = nil, retryLoad: (() async -> Void)? = nil,
                switchTeam: ((String) -> Void)? = nil, openAccount: (() -> Void)? = nil,
                filter: MacFilter = MacFilter(),
                open: @escaping (Workspace) -> Void) {
        self.store = store
        self.creator = creator
        self.accountEmail = accountEmail
        self.reconnect = reconnect
        self.linking = linking
        self.refresh = refresh
        self.retryLoad = retryLoad
        self.switchTeam = switchTeam
        self.openAccount = openAccount
        _filter = State(initialValue: filter)
        self.open = open
    }

    /// The listed Macs: one per computer, whatever builds run on it (`MacRoster`).
    private var macs: [MacDevice] { macText.roster(store.activeTeam?.macs ?? []).visible }
    /// A remembered Mac that is no longer listed reads as All Macs.
    var scope: MacScope { MacFilter.resolve(filter.scope(in: store.activeTeam), macs: macs) }
    private var scopedMac: MacDevice? { scope.macID.flatMap { id in macs.first { $0.id == id } } }
    private var target: MacDevice? {
        scope.newWorkspaceMac(available: creator.availableMacs, fallback: creator.targetMac)
    }

    func mac(_ id: String) -> MacDevice? { macs.first { $0.id == id } }

    /// Every Mac on the account (all teams): the scope of the same-name tags,
    /// as in Settings → Devices.
    private var accountMacs: [MacDevice] { MacRoster.accountMacs(store.teams) }

    /// Tags for the account's Macs that share a name, so every place that
    /// names a Mac says which one ("Aziz's MacBook Pro 3F2A").
    private var sameNames: MacNameDisambiguation { macText.names(accountMacs) }

    func displayName(_ mac: MacDevice) -> String { sameNames.displayName(mac) }

    /// Memoized: the body reads it for the rows, the subtitle, the refresh
    /// state and the animations, and it is built once per change.
    var inbox: WorkspaceInbox {
        inboxMemo.inbox(WorkspaceInbox.Memo.Input(scope: scope, macs: macs, workspaces: store.workspaces,
                                                  workspacesRevision: store.workspacesRevision, query: query,
                                                  context: WorkspaceInbox.Context(pending: store.pendingWorkspaceIDs, seenAt: store.seenAt,
                                                                                  phases: phases)))
    }

    /// The Macs with rows on screen whose list is live, for the connect timeline.
    private func liveRowMacs(_ inbox: WorkspaceInbox) -> Set<String> {
        guard store.tracksMacData else { return [] }
        return inbox.rowMacIDs.filter { store.macDataPhase($0) == .live }
    }

    /// Live mode: each Mac's data phase (nil in mock mode: every list is live).
    private var phases: [String: MacDataMachine.Phase]? {
        guard store.tracksMacData else { return nil }
        return Dictionary(macs.map { ($0.id, store.macDataPhase($0.id)) }, uniquingKeysWith: { first, _ in first })
    }

    private func listState(_ macID: String) -> WorkspaceInbox.ListState {
        store.tracksMacData ? WorkspaceInbox.ListState(store.macDataPhase(macID)) : .live
    }

    /// Refreshing: the team is loading, or the linked Mac's list has not arrived.
    private var isRefreshing: Bool { store.teamDataState == .loading || inbox.isUpdating }

    public var body: some View {
        groupDialogs(page)
    }

    private var page: some View {
        content
            .navigationTitle("Workspaces")
            .navigationSubtitle(subtitle)
            // The toolbar from plain values in a view of its own: SwiftUI skips it
            // when they did not change, so a workspace update does not rebuild
            // the bar's items (it did, at about 10 ms, on every Mac tree update).
            .background { toolbarHost }
            // The chosen Mac is the linked Mac: on a choice, on launch with a
            // remembered choice, and when the chosen Mac comes online.
            .onChange(of: scope.macToLink(in: macs), initial: true) { _, id in
                if let id { linking?.link(id) }
            }
            .task(id: isRefreshing) {
                // Say "Updating…" only when a refresh is slow, not on every one.
                guard isRefreshing else {
                    showsUpdating = false
                    return
                }
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { showsUpdating = true }
            }
            .alert(unavailableTitle, isPresented: isPresented($unavailable), presenting: unavailable) { _ in
                Button("OK", role: .cancel) {}
            } message: { ws in
                Text(unavailableMessage(ws))
            }
            .alert("Set Icon", isPresented: isPresented($iconEmoji), presenting: iconEmoji) { ws in
                TextField("Emoji", text: $emojiText)
                Button("Cancel", role: .cancel) {}
                Button("Set") { if let emoji = WorkspaceIcon.emoji(emojiText) { creator.setIcon(ws, emoji) } }
                    .disabled(WorkspaceIcon.emoji(emojiText) == nil)
                    .keyboardShortcut(.defaultAction)
            } message: { _ in
                Text("One emoji.")
            }
            .alert("Rename Workspace", isPresented: isPresented($renaming), presenting: renaming) { ws in
                TextField("Name", text: $renameText)
                    // Names and prompts are code-like: no autocorrect, no capitals (full verify D5).
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { creator.rename(ws, to: renameText) }
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
    }

    /// Move Workspace to New Group, Rename Group… and Delete Group's questions.
    private func groupDialogs(_ view: some View) -> some View {
        view
            .alert("Move Workspace to New Group", isPresented: isPresented($newGroupFor), presenting: newGroupFor) { (ws: Workspace) in
                TextField(MacWorkspaceGroup.newGroupName, text: $groupNameText)
                    // Names and prompts are code-like: no autocorrect, no capitals (full verify D5).
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    withAnimation(theme.motion.smooth.animation) { creator.moveToNewGroup(ws, name: groupNameText) }
                }
                    .keyboardShortcut(.defaultAction)
            }
            .alert("Rename Group", isPresented: isPresented($renamingGroup), presenting: renamingGroup) { (target: GroupTarget) in
                TextField("Name", text: $groupNameText)
                    // Names and prompts are code-like: no autocorrect, no capitals (full verify D5).
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { creator.renameGroup(target.group, on: target.macID, to: groupNameText) }
                    .disabled(groupNameText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .confirmationDialog(deleteGroupTitle, isPresented: isPresented($deletingGroup), titleVisibility: .visible,
                                presenting: deletingGroup) { (target: GroupTarget) in
                Button("Delete Group", role: .destructive) {
                    withAnimation(theme.motion.smooth.animation) { creator.deleteGroup(target.group, on: target.macID) }
                }
            } message: { (target: GroupTarget) in
                Text(deleteGroupMessage(target))
            }
    }

    /// "Delete “Backend”?"
    private var deleteGroupTitle: String {
        guard let target = deletingGroup else { return "" }
        return "Delete \u{201C}\(target.group.displayName)\u{201D}?"
    }

    /// The Mac keeps the workspaces (Delete Group is not Close All Workspaces in Group).
    private func deleteGroupMessage(_ target: GroupTarget) -> String {
        let name = mac(target.macID).map(displayName) ?? "the Mac"
        return "Its workspaces stay open on \(name)."
    }

    /// Filtered: the Mac and its presence. Else "Updating…" for a slow
    /// refresh, "2 need you", or with several Macs how many are online.
    private var subtitle: String {
        if let mac = scopedMac {
            return "\(displayName(mac)) · " + RelativeStamp(now: MinuteClock.shared.now).presence(isOnline: mac.isOnline, lastSeenAt: mac.lastSeenAt)
        }
        if showsUpdating && isRefreshing { return "Updating…" }
        let waiting = inbox.needsYouCount
        if waiting > 0 { return waiting == 1 ? "1 needs you" : "\(waiting) need you" }
        if macs.count > 1 { return "\(macs.filter(\.isOnline).count) of \(macs.count) Macs online" }
        return ""
    }

    private func isPresented<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    private var unavailableTitle: String {
        unavailable.flatMap { mac($0.macID) }.map { "\(displayName($0)) is offline" } ?? "Mac is offline"
    }

    private func unavailableMessage(_ ws: Workspace) -> String {
        let seen = mac(ws.macID).map { RelativeStamp(now: MinuteClock.shared.now).presence(isOnline: false, lastSeenAt: $0.lastSeenAt) } ?? "Offline"
        return "\(seen). \u{201C}\(ws.title)\u{201D} opens when the Mac is awake with cmux running."
    }

    func select(_ value: MacScope) {
        guard let team = store.activeTeam, value != scope else { return }
        theme.haptics.selection()
        withAnimation(theme.motion.smooth.animation) { filter.select(value, in: team.id) }
        // Live: the phone links one Mac at a time; showing another links it
        // (the scope's onChange). A failed Mac is dialed again on a choice.
        if let id = value.macID, mac(id)?.isOnline == true, case .failed = listState(id) {
            reconnect?(id)
        }
    }

    /// Creates a workspace and pushes it at once; the row is optimistic
    /// until the Mac confirms (ShellModel handles a refusal).
    func create(_ start: NewWorkspaceStart, directory: String?, on macID: String?) {
        guard let workspace = creator.create(start: start, directory: directory, macID: macID) else {
            theme.haptics.warning()
            return
        }
        theme.haptics.impactLight()
        open(workspace)
    }

    /// Opens a workspace: a needs-you one on its waiting tab, else the
    /// last tab used here (`AppStore.openingTab`). Clears its "Done".
    func openWorkspace(_ ws: Workspace, status: WorkspaceStatus, tab: WorkspaceTab? = nil) {
        if status == .offline {
            theme.haptics.warning()
            unavailable = ws
            return
        }
        if let tab = tab ?? (status == .needsYou ? ws.agentTab(for: .needsYou) : nil) {
            store.noteOpened(tabID: tab.id, in: ws.id)
        }
        store.markSeen(ws.id)
        // Its tabs come from its Mac: opening a workspace links that Mac.
        if let id = MacScope.macToLink(opening: ws, in: macs) { linking?.link(id) }
        open(ws)
    }

    @ViewBuilder private var content: some View {
        switch store.teamDataState {
        case .loading where store.activeWorkspaces.isEmpty || macs.isEmpty:
            skeleton
        case .failed:
            EmptyState(symbol: "cloud", title: "Couldn't load workspaces",
                       retry: retryLoad == nil ? nil : retry)
                .accessibilityIdentifier("workspaces.retry")
        case .loading, .loaded:
            if macs.isEmpty {
                ConnectMacEmptyState(
                    email: accountEmail,
                    teamName: store.teams.count > 1 ? store.activeTeam?.name : nil,
                    elsewhere: store.teamWithMacsElsewhere(),
                    switchTeam: switchTeam,
                    noMacsForAccount: store.accountMacCount == 0,
                    openAccount: openAccount
                )
            } else {
                list(inbox)
            }
        }
    }

    private var skeleton: some View {
        ScrollView { SkeletonList(rows: 6, leadingSquare: nil).padding(.top, 8) }
            .scrollDisabled(true)
            .accessibilityIdentifier("workspaces.loading")
    }

    /// The inbox as the UIKit list shows it: one collection view with a
    /// diffable data source (`WorkspacesCollection`), fed plain values. The
    /// empty states, the placeholders and the close popover's anchor stay
    /// SwiftUI over it.
    private func list(_ inbox: WorkspaceInbox) -> some View {
        WorkspacesCollection(model: listModel(inbox), actions: collectionActions, control: listControl,
                             membershipKey: inboxMemo.workspaceIDsKey &* 31 &+ inboxMemo.needsYouKey)
            // Under the bars, as the Feed's list: UIKit insets the content by them.
            .ignoresSafeArea(.container, edges: .vertical)
            .overlay(alignment: .topLeading) { closeAnchor }
            .overlay {
                if inbox.isLoading {
                    if inbox.folds.isEmpty { skeleton }
                } else if inbox.isEmpty {
                    emptyState
                }
            }
            .cmuxMobilePullDownSearch(text: $query)
            // A filter change is the person's: the list animates it.
            .animation(theme.motion.smooth.animation, value: inbox.scope)
            // verify/fast-connect.md: a Mac's rows turn live (one check for the list, not one per row).
            .onChange(of: liveRowMacs(inbox)) { old, new in
                if !new.subtracting(old).isEmpty { ConnectTimeline.shared.mark("workspace_row_live") }
            }
    }

    /// Sections and items for the collection, in the SwiftUI list's order:
    /// the asleep note, Needs You, Pinned, Recent (with its group headers),
    /// each Mac's fold, then the placeholders.
    private func listModel(_ inbox: WorkspaceInbox) -> WorkspacesListModel {
        let names = macNames()
        var rights: [String: WorkspaceCreator.MacRights] = [:]
        for mac in macs { rights[mac.id] = creator.rights(onMac: mac.id) }
        let pending = store.pendingWorkspaceIDs
        let tracks = store.tracksMacData
        var model = WorkspacesListModel()
        func add(_ section: String, _ entries: [(String, WorkspacesListItem)]) {
            guard !entries.isEmpty else { return }
            model.sections.append(ListSectionIDs(id: section, items: entries.map(\.0)))
            for (id, item) in entries where model.items[id] == nil { model.items[id] = item }
        }
        func rows(_ list: [Workspace]) -> [(String, WorkspacesListItem)] {
            list.map { ws in
                let mac = rights[ws.macID] ?? .none
                return (WorkspacesListModel.rowID(ws.id), .row(rowModel(ws, inbox, names, rights: mac, pending: pending, tracks: tracks)))
            }
        }
        if inbox.allAsleep && query.isEmpty { add("asleep", [("asleep", .asleep)]) }
        if !inbox.needsYou.isEmpty { add("needs", [("title.needs", .title("Needs You"))] + rows(inbox.needsYou)) }
        if !inbox.pinned.isEmpty { add("pinned", [("title.pinned", .title("Pinned"))] + rows(inbox.pinned)) }
        if !inbox.recent.isEmpty {
            var entries: [(String, WorkspacesListItem)] = []
            if !inbox.needsYou.isEmpty || !inbox.pinned.isEmpty || !inbox.folds.isEmpty {
                // The Mac's sidebar order when the phone knows it, else newest first.
                entries.append(("title.recent", .title(inbox.isMacOrder ? "Workspaces" : "Recent")))
            }
            for section in inbox.recentSections {
                if let group = section.group {
                    let canEdit = section.workspaces.first.map { !pending.contains($0.id) && rights[$0.macID]?.group == true } ?? false
                    entries.append(("group.\(section.id)", .group(WorkspaceGroupHeaderModel(group: group, macID: section.macID,
                                                                                              count: section.workspaces.count, canEdit: canEdit))))
                    if !group.isCollapsed { entries += rows(section.workspaces) }
                } else {
                    entries += rows(section.workspaces)
                }
            }
            add("recent", entries)
        }
        let now = MinuteClock.shared.now
        for fold in inbox.folds {
            let isOpen = fold.isForcedOpen || unfolded.contains(fold.mac.id)
            var entries: [(String, WorkspacesListItem)] = []
            // Filtered to this Mac: its rows alone; the navigation subtitle already says when it was last seen.
            if scope.macID != fold.mac.id {
                entries.append(("fold.\(fold.mac.id)", .fold(WorkspaceFoldLineModel(
                    fold: fold, isOpen: isOpen, showsLine: true, typeSize: typeSize, canReconnect: reconnect != nil,
                    sameNames: sameNames, now: now))))
            }
            if isOpen { entries += rows(fold.workspaces) }
            add("fold.\(fold.mac.id)", entries)
        }
        // Loading with Mac lines shown: the placeholder rows go below them, never over
        // them (full verify D7, D11: an overlay drew over the lines and took their Connect taps).
        if inbox.isLoading, !inbox.folds.isEmpty { add("loading", [("loading", .loading)]) }
        return model
    }

    /// The collection's per-item content and swipe actions, read when a cell
    /// is configured or swiped.
    private var collectionActions: WorkspacesCollectionActions {
        let host = self
        return WorkspacesCollectionActions(
            row: { model in WorkspaceListRow(model: model, host: host).equatable() },
            content: { _, item in host.content(item) },
            menu: { _, item in host.menu(item) },
            swipe: { _, item in host.swipeActions(item) },
            refresh: refresh
        )
    }

    private func content(_ item: WorkspacesListItem) -> AnyView {
        switch item {
        case let .row(model):
            AnyView(WorkspaceListRow(model: model, host: self).equatable())
        case let .title(title):
            AnyView(SectionTitle(title: title))
        case .asleep:
            AnyView(asleepHeader)
        case let .group(header):
            AnyView(groupHeader(header))
        case let .fold(line):
            AnyView(foldLine(line.fold))
        case .loading:
            AnyView(SkeletonList(rows: 4, leadingSquare: nil)
                .allowsHitTesting(false)
                .accessibilityIdentifier("workspaces.loading"))
        }
    }

    /// A row's or a group header's long-press menu, built when it opens.
    private func menu(_ item: WorkspacesListItem) -> UIMenu? {
        switch item {
        case let .row(model): rowMenu(model.workspace.id)
        case let .group(header): groupMenu(header)
        default: nil
        }
    }

    /// Close and Rename, trailing only: a rightward swipe from the leading edge
    /// belongs to the team sidebar.
    private func swipeActions(_ item: WorkspacesListItem) -> UISwipeActionsConfiguration? {
        guard case let .row(model) = item, model.canManage else { return nil }
        let ws = model.workspace
        let close = UIContextualAction(style: .destructive, title: "Close") { _, _, done in
            confirmClose(ws)
            done(true)
        }
        close.image = UIImage(systemName: "xmark")
        let rename = UIContextualAction(style: .normal, title: "Rename") { _, _, done in
            startRename(ws)
            done(true)
        }
        rename.image = UIImage(systemName: "pencil")
        rename.backgroundColor = .systemGray
        let configuration = UISwipeActionsConfiguration(actions: [close, rename])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    /// Each listed Mac's name as the list writes it (with its same-name tag),
    /// worked out once per pass for every row.
    private func macNames() -> [String: String] {
        let sameNames = sameNames
        return Dictionary(macs.map { ($0.id, sameNames.displayName($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// A row's values. `rights` is its Mac's (`WorkspaceCreator.rights(onMac:)`),
    /// worked out once per pass: the same answers as `canManage`, `canArrange`
    /// and `canDuplicate` for this workspace.
    private func rowModel(_ ws: Workspace, _ inbox: WorkspaceInbox, _ names: [String: String], rights: WorkspaceCreator.MacRights,
                          pending: Set<String>, tracks: Bool) -> WorkspaceRowModel {
        let status = inbox.status(ws)
        let macName = names[ws.macID]
        let canManage = status != .offline && !pending.contains(ws.id) && rights.manage
        let canArrange = canManage && rights.arrange
        let moves = canArrange ? inbox.moves(of: ws) : (up: false, down: false)
        return WorkspaceRowModel(workspace: ws, status: status, macName: inbox.showsMacNames ? macName : nil,
                                 offlineMacName: status == .offline ? macName : nil, isStale: inbox.stale.contains(ws.id),
                                 tracksMacData: tracks, canManage: canManage, canArrange: canArrange,
                                 canDuplicate: canManage && !ws.isHome, canMoveUp: moves.up, canMoveDown: moves.down)
    }

    /// A Mac workspace group's header, as its sidebar shows it: a tap folds or
    /// unfolds it (Collapse / Expand Workspace Group, on the Mac too); hold it
    /// for the Mac's group actions.
    private func groupHeader(_ header: WorkspaceGroupHeaderModel) -> some View {
        let (group, canEdit) = (header.group, header.canEdit)
        return Button {
            guard canEdit else { return }
            theme.haptics.selection()
            withAnimation(theme.motion.smooth.animation) { creator.setGroupCollapsed(group, on: header.macID, !group.isCollapsed) }
        } label: {
            GroupHeaderLabel(group: group, count: header.count)
                // The row's spacing is part of the target (it was the text's
                // line only, about 17 pt): same layout, a 32 pt tap target.
                .padding(.top, 10)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // From the screen edge, as the rows: the chevron in their gutter, the
        // name at their titles' x.
        .accessibilityAddTraits(.isHeader)
        .accessibilityActions { groupAccessibilityActions(group, macID: header.macID, canEdit: canEdit) }
        .accessibilityIdentifier("workspace.group.\(group.id)")
    }

    @ViewBuilder private func groupAccessibilityActions(_ group: MacWorkspaceGroup, macID: String, canEdit: Bool) -> some View {
        if canEdit {
            Button("Rename Group…") { startRenameGroup(group, macID: macID) }
            Button("Delete Group") { deletingGroup = GroupTarget(group: group, macID: macID) }
        }
    }

    func startRenameGroup(_ group: MacWorkspaceGroup, macID: String) {
        groupNameText = group.name
        renamingGroup = GroupTarget(group: group, macID: macID)
    }

    /// Asks before closing, in a popover pointing at the row (Mail).
    func confirmClose(_ ws: Workspace) {
        let present = {
            closingFrame = rowFrames.frame(of: ws.id) ?? .zero
            closing = ws
        }
        // At accessibility sizes the popover is about as tall as the screen
        // and fits only under a row near the top: bring the row up first, then
        // point at it where it is (round 2 review: it pointed 80 pt off).
        guard typeSize.isAccessibilitySize else { return present() }
        listControl.scrollTo(WorkspacesListModel.rowID(ws.id), atTop: true, animated: true, completion: present)
    }

    /// The close popover's anchor: a view over the list at the row's place.
    /// Not on the row itself: a row's own presentation is dropped while its
    /// swipe actions close.
    private var closeAnchor: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { FrameProbe(id: "anchor") { rowFrames.anchor = $0 } }
            .overlay(alignment: .topLeading) { anchor }
            .allowsHitTesting(false)
    }

    private var anchor: some View {
        Color.clear
            .frame(width: max(closingFrame.width, 1), height: max(closingFrame.height, 1))
            // Padding, not an offset: the popover points at the layout frame.
            .padding(.leading, max(closingFrame.minX, 0))
            .padding(.top, max(closingFrame.minY, 0))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .confirmationDialog(bulkClosing.map { WorkspaceBulkClose.question($0.targets.count) } ?? "", isPresented: isPresented($bulkClosing),
                                titleVisibility: .visible, presenting: bulkClosing) { bulk in
                Button(bulk.targets.count == 1 ? "Close Workspace" : "Close Workspaces", role: .destructive) {
                    theme.haptics.impactLight()
                    withAnimation(theme.motion.smooth.animation) {
                        if bulk.groups.isEmpty {
                            creator.close(bulk.targets)
                        } else {
                            creator.closeGroups(bulk.groups, on: bulk.workspace.macID)
                        }
                    }
                }
            } message: { bulk in
                Text(bulk.message(macName: mac(bulk.workspace.macID).map(displayName) ?? "the Mac"))
            }
            .confirmationDialog(closing.map { "Close \u{201C}\($0.title)\u{201D}?" } ?? "", isPresented: isPresented($closing),
                                titleVisibility: .visible, presenting: closing) { ws in
                Button("Close Workspace", role: .destructive) {
                    theme.haptics.impactLight()
                    withAnimation(theme.motion.smooth.animation) { creator.close(ws) }
                }
            } message: { ws in
                Text("Its tabs close on \(mac(ws.macID).map(displayName) ?? "the Mac").")
            }
    }

    /// Set Icon… › Emoji…: asks for the emoji.
    func startIconEmoji(_ ws: Workspace) {
        emojiText = ""
        iconEmoji = ws
    }

    /// Move Workspace to New Group: asks for the name.
    func startNewGroup(_ ws: Workspace) {
        groupNameText = ""
        newGroupFor = ws
    }

    /// Close Other / Above / Below: asks first, in the popover.
    func confirmBulkClose(_ bulk: BulkClose) { bulkClosing = bulk }

    func confirmDeleteGroup(_ target: GroupTarget) { deletingGroup = target }

    func startRename(_ ws: Workspace) {
        renameText = ws.title
        renaming = ws
    }

    /// "Aziz's Mac Studio · feat-cmux-next-ios", "· Offline" for an offline Mac.
    func menuHeader(_ ws: Workspace, macName: String, offline: Bool) -> String {
        var parts = [macName]
        if !ws.place.isEmpty { parts.append(ws.place) }
        if offline { parts.append("Offline") }
        return parts.joined(separator: " · ")
    }

    /// One line for an offline Mac ("MacBook Pro · Last seen 2h ago  3 ›"),
    /// unfolding its rows in place; or for an online Mac the phone is not
    /// linked to (live), linking it on a tap.
    private func foldLine(_ fold: WorkspaceInbox.Fold) -> some View {
        let isOpen = fold.isForcedOpen || unfolded.contains(fold.mac.id)
        let detail = switch fold.reason {
        case .offline: RelativeStamp(now: MinuteClock.shared.now).presence(isOnline: false, lastSeenAt: fold.mac.lastSeenAt)
        case .notConnected: "Not connected"
        case .failed: "Can't connect"
        }
        return Button {
            switch fold.reason {
            case .offline:
                theme.haptics.selection()
                let opening = !unfolded.contains(fold.mac.id)
                withAnimation(theme.motion.smooth.animation) {
                    if opening { unfolded.insert(fold.mac.id) } else { unfolded.remove(fold.mac.id) }
                }
                // Rows opening below the visible area: bring the first into view.
                if opening, let first = fold.workspaces.first,
                   (rowFrames.frame(of: "fold.\(fold.mac.id)")?.maxY ?? 0) + WorkspaceRow.minHeight > listControl.visibleBottom {
                    Task { @MainActor in
                        await Task.yield()
                        listControl.scrollTo(WorkspacesListModel.rowID(first.id), atTop: false, animated: true)
                    }
                }
            case .notConnected, .failed:
                reconnect?(fold.mac.id)
            }
        } label: {
            HStack(spacing: 0) {
                // The glyph in the rows' gutter, the Mac's name at their titles' x.
                Image(systemName: fold.reason == .offline ? "moon.zzz" : "bolt.horizontal.circle")
                    .frame(width: gutter)
                    .accessibilityHidden(true)
                // The name with its tag capsule, as Settings → Devices shows it;
                // the plain text form when the capsule line doesn't fit.
                // At accessibility sizes: name (never broken mid-word), the tag
                // on its own line, then the presence, as Devices does.
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 4) {
                            UnbrokenText(fold.mac.name, style: .footnote, weight: .semibold)
                            if let tag = sameNames.tag(for: fold.mac.id) { MacNameTag(tag) }
                            UnbrokenText(detail, style: .footnote, weight: .semibold)
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) {
                                Text(fold.mac.name).lineLimit(1)
                                if let tag = sameNames.tag(for: fold.mac.id) { MacNameTag(tag) }
                                Text("· \(detail)").lineLimit(1)
                            }
                            Text("\(displayName(fold.mac)) · \(detail)")
                                .lineLimit(3)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(displayName(fold.mac)) · \(detail)"))
                Spacer(minLength: 8)
                if fold.reason != .offline {
                    if reconnect != nil { Text(fold.reason == .notConnected ? "Connect" : "Retry") }
                } else if !fold.isForcedOpen {
                    Text("\(fold.workspaces.count)")
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .animation(theme.motion.snap.animation, value: isOpen)
                        .padding(.leading, 6)
                        .accessibilityHidden(true)
                }
            }
            .font(theme.type.meta.weight(.semibold))
            .foregroundStyle(theme.colors.label2)
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(fold.isForcedOpen || (fold.reason != .offline && reconnect == nil))
        .accessibilityValue(fold.reason == .offline && !fold.isForcedOpen ? (isOpen ? "Expanded" : "Collapsed") : "")
        .background { FrameProbe(id: "fold.\(fold.mac.id)") { rowFrames.rows["fold.\(fold.mac.id)"] = WeakProbe(view: $0) } }
        .accessibilityIdentifier("workspaces.fold.\(fold.mac.id)")
    }

    private var asleepHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 28))
                .foregroundStyle(theme.colors.label)
                .accessibilityHidden(true)
            Text("Your Macs are asleep")
                .font(theme.type.emptyTitle)
                .foregroundStyle(theme.colors.label)
            Text("Wake a Mac or open cmux on it to open its workspaces.")
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspaces.empty.asleep")
    }

    @ViewBuilder private var emptyState: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: query)
        } else if let mac = scopedMac {
            scopedEmptyState(mac)
        } else if let target {
            EmptyState(
                symbol: "macwindow",
                title: "No workspaces",
                message: "New workspaces open right away on \(displayName(target)).",
                primaryTitle: "New Workspace",
                primary: { create(.terminal, directory: nil, on: target.id) }
            )
            .accessibilityIdentifier("workspaces.empty.all")
        } else {
            EmptyState(
                symbol: "moon.zzz",
                title: "Your Macs are asleep",
                message: "Wake a Mac or open cmux on it to see its workspaces."
            )
            .accessibilityIdentifier("workspaces.empty.asleep")
        }
    }

    /// Filtered to an online Mac with no rows (`MacEmptyState`). Never
    /// "can't take new workspaces" while the phone is still linking it.
    @ViewBuilder private func scopedEmptyState(_ mac: MacDevice) -> some View {
        let canCreate = target != nil
        switch MacEmptyState.resolve(isOnline: mac.isOnline, list: listState(mac.id), connection: store.macConnection[mac.id],
                                     tracksLive: store.tracksMacData, reach: linking?.reach(mac.id) ?? .none, canCreate: canCreate) {
        case .offline:
            EmptyState(
                symbol: "moon.zzz",
                title: "\(displayName(mac)) is offline",
                message: "\(RelativeStamp(now: MinuteClock.shared.now).presence(isOnline: false, lastSeenAt: mac.lastSeenAt)). Open cmux on it to see its workspaces."
            )
            .accessibilityIdentifier("workspaces.empty.offline")
        case .failed:
            EmptyState(
                symbol: "bolt.horizontal.circle",
                title: "Can't connect to \(displayName(mac))",
                message: "\(displayName(mac)) is online, but this iPhone can't reach it.",
                primaryTitle: reconnect == nil ? nil : "Retry",
                primary: reconnect.map { reconnect in { reconnect(mac.id) } }
            )
            .accessibilityIdentifier("workspaces.failed")
        case .notConnected:
            EmptyState(
                symbol: "link",
                title: "\(displayName(mac)) isn't connected",
                message: "Connect to this Mac to view its workspaces.",
                primaryTitle: reconnect == nil ? nil : "Connect",
                primary: reconnect.map { reconnect in { reconnect(mac.id) } }
            )
            .accessibilityIdentifier("workspaces.empty.not-connected")
        case .othersMac:
            EmptyState(
                symbol: "person.crop.circle.badge.questionmark",
                title: "\(displayName(mac)) belongs to a teammate",
                message: "Only the account that added \(displayName(mac)) can open its workspaces."
            )
            .accessibilityIdentifier("workspaces.empty.others-mac")
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(displayName(mac))…")
                    .font(theme.type.rowSubtitle)
                    .foregroundStyle(theme.colors.label2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workspaces.empty.connecting")
        case .empty(let canCreate):
            EmptyState(
                symbol: "macwindow",
                title: "No workspaces on \(displayName(mac))",
                message: canCreate ? "New workspaces open right away." : "\(displayName(mac)) can't take new workspaces from this iPhone.",
                primaryTitle: canCreate ? "New Workspace" : nil,
                primary: canCreate ? { create(.terminal, directory: nil, on: mac.id) } : nil
            )
            .accessibilityIdentifier("workspaces.empty.mac")
        }
    }

    private var toolbarHost: some View {
        let target = target
        let macs = macs
        let entries = macs.count > 1 ? macText.entries(MacFilterMemo.Input(macs: macs, accountMacs: accountMacs, connection: store.macConnection,
                                                                           linkStatus: store.macLinkStatus, live: store.tracksMacData,
                                                                           now: MinuteClock.shared.now)) : []
        let filterValue = scopedMac.map { mac in
            [displayName(mac), entries.first { $0.id == mac.id }?.detail].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", ")
        } ?? "All Macs"
        let model = WorkspacesToolbar.Model(
            showsFilter: macs.count > 1, entries: entries, scope: scope, filterValue: filterValue, target: target,
            showsMacPicker: scope == .all, sameNames: sameNames,
            recents: target.map { creator.recentDirectories(on: $0.id) } ?? [],
            options: target.map { creator.options(on: $0.id) }, availableMacs: creator.availableMacs
        )
        return WorkspacesToolbar(model: model, host: self).equatable()
    }

    /// On for the chosen scope; turning one on chooses it (turning the chosen one off does nothing).
    func chosen(_ value: MacScope) -> Binding<Bool> {
        Binding(get: { scope == value }, set: { if $0 { select(value) } })
    }

    func retry() async {
        await retryLoad?()
    }
}

/// A row's inputs as plain values: SwiftUI compares them and skips the row
/// (its body, menu and accessibility actions) when none changed, so an update
/// costs O(changed rows), not O(rows).
struct WorkspaceRowModel: Equatable {
    var workspace: Workspace
    var status: WorkspaceStatus
    /// Named on idle rows when Recent mixes several Macs.
    var macName: String?
    var offlineMacName: String?
    /// A last-known (cached) row, dimmed.
    var isStale: Bool
    var tracksMacData: Bool
    var canManage: Bool
    var canArrange: Bool
    var canDuplicate: Bool
    var canMoveUp: Bool
    var canMoveDown: Bool
}

/// One Workspaces row and what it carries: the tap, the press fill, the
/// stale dimming, the menu (built when shown) and the accessibility actions.
/// Equal models skip the body; `host` only runs actions and is not compared.
struct WorkspaceListRow: View, Equatable {
    let model: WorkspaceRowModel
    let host: WorkspacesList

    nonisolated static func == (a: Self, b: Self) -> Bool { a.model == b.model }

    var body: some View {
        let ws = model.workspace
        let host = host
        Button {
            host.openWorkspace(ws, status: model.status)
        } label: {
            WorkspaceRow(workspace: ws, status: model.status, macName: model.macName, offlineMacName: model.offlineMacName)
        }
        // Not the List's cell highlight: it stuck on as a gray pill while a
        // swipe was under way. A press fill that ends when the touch moves.
        .buttonStyle(RowPressStyle())
        // Last-known rows (live mode), dimmed until the Mac answers on this link.
        .opacity(model.isStale ? 0.55 : 1)
        .animation(theme.motion.smooth.animation, value: model.isStale)
        .onAppear {
            // verify/fast-connect.md: when a row is first on screen, cached or live.
            if model.tracksMacData {
                ConnectTimeline.shared.mark(model.isStale ? "workspace_row_cached" : "workspace_row_live")
            }
        }
        // Where the row is, so the close popover can point at it.
        .background { FrameProbe(id: ws.id) { host.rowFrames.rows[ws.id] = WeakProbe(view: $0) } }
        .accessibilityActions {
            if model.canManage {
                if model.canArrange {
                    Button(ws.isPinned ? "Unpin Workspace" : "Pin Workspace") { host.creator.setPinned(ws, !ws.isPinned) }
                    if model.canMoveUp {
                        Button("Move Workspace Up") { host.creator.move(ws, by: -1, among: host.inbox.macOrder(of: ws)) }
                    }
                    if model.canMoveDown {
                        Button("Move Workspace Down") { host.creator.move(ws, by: 1, among: host.inbox.macOrder(of: ws)) }
                    }
                }
                Button("Rename") { host.startRename(ws) }
                if model.canDuplicate { Button(WorkspaceCreator.duplicateTitle) { host.creator.duplicate(ws) } }
                Button("Close") { host.confirmClose(ws) }
            }
        }
        .accessibilityIdentifier("workspace.row.\(ws.id)")
    }
}

/// The Workspaces toolbar: the Mac filter and New Workspace, drawn from plain
/// values (`Model`). Equal models skip it, so the bar's items are rebuilt only
/// when what they show changes. `host` only runs actions and is not compared.
struct WorkspacesToolbar: View, Equatable {
    struct Model: Equatable {
        var showsFilter: Bool
        var entries: [MacFilterMemo.Entry]
        var scope: MacScope
        /// The chosen Mac and its presence and link line, for VoiceOver.
        var filterValue: String
        var target: MacDevice?
        var showsMacPicker: Bool
        var sameNames: MacNameDisambiguation
        var recents: [String]
        /// What New Workspace offers on the target Mac, and the Macs it can create on.
        var options: WorkspaceCreationOptions?
        var availableMacs: [MacDevice]
    }

    let model: Model
    let host: WorkspacesList

    nonisolated static func == (a: Self, b: Self) -> Bool { a.model == b.model }

    var body: some View {
        let model = model
        let host = host
        Color.clear
            .accessibilityHidden(true)
            .toolbar {
                // Each item an Equatable view: SwiftUI re-hosts every bar item when
                // any preference of the screen changes (each list update), and an
                // equal item then skips its menu, its labels and their symbol lookups.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.showsFilter { WorkspacesFilterMenu(model: model, host: host).equatable() }
                    NewWorkspaceButton(creator: host.creator, target: model.target, showsMacPicker: model.showsMacPicker,
                                       sameNames: model.sameNames, recents: model.recents, options: model.options,
                                       macs: model.availableMacs) { start, directory in
                        host.create(start, directory: directory, on: model.target?.id)
                    }
                    .equatable()
                }
            }
    }
}

/// The Mac filter: All Macs, then each Mac (online first) with its presence
/// (and the live link line) as the subtitle.
struct WorkspacesFilterMenu: View, Equatable {
    let model: WorkspacesToolbar.Model
    let host: WorkspacesList

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.model.entries == b.model.entries && a.model.scope == b.model.scope && a.model.filterValue == b.model.filterValue
    }

    var body: some View {
        Menu {
            // Toggles, not an inline Picker: a Picker drops each Mac's
            // presence subtitle. The chosen row shows the checkmark.
            Toggle(isOn: host.chosen(.all)) {
                Label("All Macs", systemImage: "square.stack.3d.up")
            }
            .accessibilityIdentifier("workspaces.filter.all")
            ForEach(model.entries) { mac in
                // A title and a subtitle Text directly in the label: a menu
                // shows the second as the subtitle (not inside a Label).
                Toggle(isOn: host.chosen(.mac(mac.id))) {
                    Text(mac.title)
                    Text(mac.detail)
                    // The model has no Mac kind (laptop or desktop) yet.
                    Image(systemName: "desktopcomputer")
                }
                .accessibilityIdentifier("workspaces.filter.\(mac.id)")
            }
        } label: {
            Label("Filter", systemImage: model.scope == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("workspaces.filter")
        // The chosen Mac and its presence and link line ("Online · Connected
        // over WebRTC"), so VoiceOver (and the rig's link reader) hears the
        // link without opening the menu.
        .accessibilityValue(model.filterValue)
    }
}

/// Where rows are, read when Close is tapped: each row and the anchor
/// overlay carry a UIKit probe view, and the row's probe is converted into
/// the overlay's space at that moment. (SwiftUI geometry callbacks inside
/// list cells did not follow scrolling, so a stored frame went stale.) A
/// plain reference: registering never re-renders the list.
final class RowFrames {
    var rows: [String: WeakProbe] = [:]
    weak var anchor: FrameProbe.Probe?

    /// The row's frame in the anchor overlay, now; nil when it is not on screen.
    func frame(of id: String) -> CGRect? {
        guard let probe = rows[id]?.view, probe.id == id, probe.window != nil, let anchor else { return nil }
        return probe.convert(probe.bounds, to: anchor)
    }
}

struct WeakProbe {
    weak var view: FrameProbe.Probe?
}

/// An invisible UIKit view the size of its SwiftUI parent, tagged with an id.
struct FrameProbe: UIViewRepresentable {
    let id: String
    let register: (Probe) -> Void

    final class Probe: UIView {
        var id = ""
    }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.id = id
        register(probe)
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        // A reused cell carries another row now.
        probe.id = id
        register(probe)
    }
}

/// A row's press feedback: the `fillSelected` color behind the whole row
/// while the finger is down. A scroll or a swipe cancels the press, so it
/// never stays on behind swipe actions.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                theme.colors.fillSelected.color
                    .opacity(configuration.isPressed ? 1 : 0)
                    .padding(.vertical, -10)
                    .padding(.trailing, -20)
            }
    }
}

/// A section title as a row that scrolls with the list (not a pinned
/// header: pinned plain headers overlap rows under the glass bar). It starts
/// at the rows' titles, after their status gutter (SPEC 4.2.1: one text column).
struct SectionTitle: View {
    let title: String
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The title's x from the screen edge: the rows' text column.
    static func leading(_ size: DynamicTypeSize) -> CGFloat { CmuxMobileListColumn.plain(size).text }

    var body: some View {
        Text(title)
            .font(theme.type.meta.weight(.semibold))
            .foregroundStyle(theme.colors.label2)
            .frame(maxWidth: .infinity, alignment: .leading)
            // At the rows' text column (the cell's margins put it at the screen edge).
            .padding(.leading, Self.leading(typeSize))
            .accessibilityAddTraits(.isHeader)
    }
}

/// A group header's label: a disclosure chevron, the group's color, its name,
/// and how many workspaces it holds while folded.
struct GroupHeaderLabel: View {
    let group: MacWorkspaceGroup
    let count: Int
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // From the screen edge: the chevron centered in the rows' status
        // gutter, the name at their titles' x, its color dot after it.
        HStack(spacing: 0) {
            Image(systemName: "chevron.right")
                .font(theme.type.meta.weight(.semibold))
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                .foregroundStyle(theme.colors.label2)
                .frame(width: Self.titleLeading(typeSize))
            Text(group.displayName)
                .font(theme.type.meta.weight(.semibold))
                .foregroundStyle(theme.colors.label)
                .lineLimit(1)
            Circle()
                .fill(swatch)
                .frame(width: 8, height: 8)
                .padding(.leading, 8)
            Spacer(minLength: 8)
            if group.isCollapsed {
                Text(String(count))
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.displayName)
        .accessibilityValue(group.isCollapsed ? "Collapsed, \(count) workspaces" : "Expanded")
    }

    private var swatch: Color {
        WorkspaceSwatch.color(stored: group.color) ?? theme.colors.label3.color
    }

    /// The name's x from the screen edge: the rows' text column.
    static func titleLeading(_ size: DynamicTypeSize) -> CGFloat { CmuxMobileListColumn.plain(size).text }
}

/// A Mac workspace group the person is renaming or deleting.
struct GroupTarget: Identifiable {
    var group: MacWorkspaceGroup
    var macID: String
    var id: String { "\(macID)-\(group.id)" }
}

/// A bulk close waiting for the person's answer.
struct BulkClose: Identifiable {
    var kind: WorkspaceBulkClose
    var workspace: Workspace
    var targets: [Workspace]
    /// Close All in Group / Close Other Groups: the groups that close with their workspaces.
    var groups: [MacWorkspaceGroup] = []
    var id: String { "\(kind.rawValue)-\(workspace.id)-\(groups.map(\.id).joined(separator: ","))" }

    /// "a, b and c close on <Mac>, with their tabs."
    func message(macName: String) -> String {
        let names = targets.map(\.title)
        let list = names.count <= 4 ? ListFormatter.localizedString(byJoining: names)
            : ListFormatter.localizedString(byJoining: Array(names.prefix(3)) + ["\(names.count - 3) more"])
        return "\(list) close on \(macName), with their tabs."
    }
}

/// The Mac's workspace color swatch (its `GroupColor.swatch` hue, chroma and brightness).
enum WorkspaceSwatch {
    static func color(_ color: WorkspaceColor) -> Color {
        let (hue, chroma) = color.hueAndChroma
        return Color(UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            return UIColor(hue: hue / 360, saturation: (dark ? 0.40 : 0.42) * chroma, brightness: dark ? 0.68 : 0.64, alpha: 1)
        })
    }

    /// A stored color: a palette name, or `#RRGGBB`.
    static func color(stored: String?) -> Color? {
        if let palette = WorkspaceColor(stored: stored) { return color(palette) }
        guard let stored, stored.hasPrefix("#"), stored.count >= 7, let value = UInt32(stored.dropFirst().prefix(6), radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// A menu icon: a filled circle in the color (menus draw images, not shapes).
    /// Drawn once per color: a menu lists nine of them.
    @MainActor static func image(_ color: WorkspaceColor) -> Image { Image(uiImage: uiImage(color)) }

    /// The same circle for a UIKit menu, drawn once per color.
    @MainActor static func uiImage(_ color: WorkspaceColor) -> UIImage {
        if let image = images[color] { return image }
        let (hue, chroma) = color.hueAndChroma
        let fill = UIColor(hue: hue / 360, saturation: 0.42 * chroma, brightness: 0.64, alpha: 1)
        let size = CGSize(width: 16, height: 16)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            fill.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        }.withRenderingMode(.alwaysOriginal)
        images[color] = image
        return image
    }

    @MainActor private static var images: [WorkspaceColor: UIImage] = [:]

    /// Whether the phone draws `name` as an SF Symbol (a workspace icon is a
    /// symbol or an emoji), looked up once per name, not on every row pass.
    @MainActor static func isSymbol(_ name: String) -> Bool {
        if let known = symbols[name] { return known }
        let known = UIImage(systemName: name) != nil
        symbols[name] = known
        return known
    }

    @MainActor private static var symbols: [String: Bool] = [:]
}

/// SPEC 11.1 workspace row, Mail anatomy: a status gutter (32 pt at Large,
/// scaling with Dynamic Type), then the name and its time, then the status
/// sentence.
struct WorkspaceRow: View {
    let workspace: Workspace
    let status: WorkspaceStatus
    /// Named on idle rows when Recent mixes several Macs.
    var macName: String?
    /// The offline Mac, for the VoiceOver hint.
    var offlineMacName: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The status gutter; the title, separators and section titles start after it.
    private var gutter: CGFloat { Self.textLeading(typeSize) }
    private var needsYouDisc: CGFloat { Self.scaled(10, typeSize) }
    private var doneDisc: CGFloat { Self.scaled(8, typeSize) }

    /// `value` at Large, scaled like `.body` for the environment's Dynamic
    /// Type size (the same curve as the row's text). Not `@ScaledMetric`: in
    /// list rows it scaled 32 pt to about 64 pt at Large (round 2 review).
    static func scaled(_ value: CGFloat, _ size: DynamicTypeSize) -> CGFloat {
        CmuxMobileListColumn.scaled(value, size)
    }

    /// The gutter at Large (`CmuxMobileListColumn.plainGutter`).
    static let gutter: CGFloat = CmuxMobileListColumn.plainGutter
    /// The title's x from the screen edge (rows have no leading inset).
    static func textLeading(_ size: DynamicTypeSize) -> CGFloat { CmuxMobileListColumn.plain(size).text }
    /// About one row: unfolding scrolls when the first new row would not fit.
    static let minHeight: CGFloat = 60

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            mark
                .frame(width: gutter)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + needsYouDisc / 2 }
                .animation(theme.motion.snap.animation, value: status)
            VStack(alignment: .leading, spacing: 3) {
                // The time stays trailing on line 1, beside a name that wraps
                // to two lines at accessibility sizes (no line of its own).
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    name.lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    Spacer(minLength: 8)
                    time
                }
                StatusLine(workspace: workspace, status: status, macName: macName)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .opacity(status == .offline ? 0.6 : 1)
            }
        }
        .frame(minHeight: 40, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint(offlineMacName.map { "\($0) is offline" } ?? "")
        .accessibilityAddTraits(.isButton)
    }

    private var name: some View {
        HStack(spacing: 5) {
            // The Mac's workspace icon: an SF Symbol the phone draws, else an emoji.
            if let icon = workspace.icon, !icon.isEmpty {
                if WorkspaceSwatch.isSymbol(icon) {
                    Image(systemName: icon).font(theme.type.rowTitle).foregroundStyle(theme.colors.label2)
                        .accessibilityIdentifier("workspace.icon")
                } else if WorkspaceIcon.emoji(icon) != nil {
                    Text(icon).font(theme.type.rowTitle).accessibilityIdentifier("workspace.icon")
                }
            }
            Text(workspace.title)
                .font(theme.type.rowTitle.weight(.semibold))
                .foregroundStyle(status == .offline ? theme.colors.label3 : theme.colors.label)
        }
    }

    /// Only a real activity time: none for a live workspace with no activity
    /// seen since the phone connected.
    @ViewBuilder private var time: some View {
        if workspace.hasActivityTime {
            Text(RelativeStamp(now: MinuteClock.shared.now).string(for: workspace.lastActivityAt))
                .font(theme.type.meta)
                .monospacedDigit()
                .foregroundStyle(status == .needsYou ? theme.colors.label : theme.colors.label2)
                .fixedSize()
        }
    }

    @ViewBuilder private var mark: some View {
        switch status {
        case .needsYou:
            Circle().fill(theme.colors.warning.color).frame(width: needsYouDisc, height: needsYouDisc)
                .accessibilityIdentifier("workspace.needs-you")
        case .working, .creating:
            ProgressView().controlSize(.mini)
                .accessibilityIdentifier(status == .working ? "workspace.working" : "workspace.creating")
        case .done:
            Circle().fill(theme.colors.label.color).frame(width: doneDisc, height: doneDisc)
                .accessibilityIdentifier("workspace.done")
        case .idle, .offline:
            // The Mac's workspace color, when it has one.
            if let color = WorkspaceSwatch.color(stored: workspace.colorHex) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: doneDisc / 2, height: doneDisc * 2)
                    .accessibilityIdentifier("workspace.color")
            } else {
                Color.clear.frame(width: doneDisc, height: doneDisc)
            }
        }
    }

    private var spoken: String {
        var parts = [workspace.title]
        if workspace.isPinned { parts.append("pinned") }
        if let color = WorkspaceColor(stored: workspace.colorHex) { parts.append(color.title) }
        let line = StatusLine.words(workspace, status: status, macName: macName)
        parts.append(contentsOf: line)
        if workspace.hasActivityTime, status != .creating {
            parts.append(RelativeStamp(now: MinuteClock.shared.now).spoken(for: workspace.lastActivityAt))
        }
        return parts.joined(separator: ", ")
    }
}

/// Line 2 of a row: "**Claude is asking permission** · Refactor transport layer"
/// (or "has a question"; "is waiting" for a terminal agent),
/// "Codex is working · Fix pricing page" (shimmering), "**Done** · Claude:
/// Audit runner labels", else the branch or directory.
struct StatusLine: View {
    let workspace: Workspace
    let status: WorkspaceStatus
    var macName: String?

    var body: some View {
        Group {
            switch status {
            case .needsYou:
                if let task { Text("\(emphasis(waiting)) · \(task)") } else { emphasis(waiting) }
            case .working:
                // One text under the shimmer, so it truncates as one line.
                ShimmerText(text: [working, task].compactMap(\.self).joined(separator: " · "))
            case .done:
                if let task { Text("\(emphasis("Done")) · \(agentName ?? "Agent"): \(task)") } else { emphasis("Done") }
            case .creating:
                Text(workspace.directory.isEmpty ? "Creating…" : Self.directoryName(workspace.directory))
            case .idle, .offline:
                Text(Self.place(workspace, macName: macName))
            }
        }
        .font(theme.type.rowSubtitle)
        .foregroundStyle(theme.colors.label2)
        .contentTransition(.opacity)
    }

    private var tab: WorkspaceTab? { workspace.agentTab(for: status) }
    private var agentName: String? { tab?.agentName }
    private var task: String? { tab?.task }
    private var waiting: String { tab?.waitingPhrase ?? "Needs you" }
    private var working: String { agentName.map { "\($0) is working" } ?? "Working" }

    private func emphasis(_ word: String) -> Text {
        Text(word).foregroundStyle(theme.colors.label).fontWeight(.semibold)
    }

    /// "Home" for the home directory, as the New Workspace menu says.
    static func directoryName(_ directory: String) -> String {
        directory == "~" ? "Home" : directory
    }

    static func place(_ workspace: Workspace, macName: String?) -> String {
        let place = workspace.branch ?? (workspace.directory.isEmpty ? nil : directoryName(workspace.directory))
        return [place, macName].compactMap(\.self).joined(separator: " · ")
    }

    /// The same line for VoiceOver.
    static func words(_ workspace: Workspace, status: WorkspaceStatus, macName: String?) -> [String] {
        let tab = workspace.agentTab(for: status)
        switch status {
        case .needsYou: return [tab?.waitingPhrase ?? "Needs you", tab?.task].compactMap(\.self)
        case .working: return [tab.map { "\($0.agentName) is working" } ?? "Working", tab?.task].compactMap(\.self)
        case .done: return ["Done", tab.map { "\($0.agentName)" }, tab?.task].compactMap(\.self)
        case .creating: return ["Creating"]
        case .idle: return ["idle", place(workspace, macName: macName)]
        case .offline: return ["offline", place(workspace, macName: nil)]
        }
    }
}

/// SPEC 4.5's shimmer for a row's "is working" line: `label2` at rest (never
/// fainter than the rest of line 2), a `label` highlight sweeping across.
/// Static `label2` with Reduce Motion. The sweep is a Core Animation
/// animation that runs on the render server: no per-frame body, layout or
/// main-thread work while rows shimmer (it was a `TimelineView(.animation)`
/// with a `GeometryReader` mask, a body per working row per frame).
struct ShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .foregroundStyle(theme.colors.label2)
            .overlay {
                if !reduceMotion {
                    ShimmerHighlight(text: text)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// The highlight over a `ShimmerText`: the same text in `label`, seen through
/// a gradient band that sweeps leading to trailing every 1.6 s, every row in
/// step (the phase comes from the clock, as the old timeline's did).
private struct ShimmerHighlight: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> ShimmerHighlightView { ShimmerHighlightView() }

    func updateUIView(_ view: ShimmerHighlightView, context: Context) {
        let environment = context.environment
        // The row's line 2 font (`theme.type.rowSubtitle`, `.subheadline`) at the row's Dynamic Type size.
        let traits = UITraitCollection { traits in
            traits.preferredContentSizeCategory = UIContentSizeCategory(environment.dynamicTypeSize)
            traits.legibilityWeight = environment.legibilityWeight == .bold ? .bold : .regular
        }
        view.configure(text: text, font: UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits),
                       lines: environment.lineLimit ?? 0)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ShimmerHighlightView, context: Context) -> CGSize? {
        // An overlay: exactly the text's frame.
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

final class ShimmerHighlightView: UIView {
    private let label = UILabel()
    private let band = CAGradientLayer()
    private var sweptSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        label.textColor = theme.colors.label.uiColor
        label.lineBreakMode = .byTruncatingTail
        label.textAlignment = .natural
        addSubview(label)
        band.colors = [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.anchorPoint = .zero
        label.layer.mask = band
        // The system drops layer animations while the app is in the background.
        NotificationCenter.default.addObserver(self, selector: #selector(restartSweep),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(text: String, font: UIFont, lines: Int) {
        if label.text != text { label.text = text }
        if label.font != font { label.font = font }
        if label.numberOfLines != lines { label.numberOfLines = lines }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        if bounds.size != sweptSize { startSweep() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startSweep() }
    }

    @objc private func restartSweep() { startSweep() }

    private func startSweep() {
        let width = bounds.width
        guard width > 0, window != nil else { return }
        sweptSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.bounds = CGRect(x: 0, y: 0, width: max(width * 0.4, 30), height: bounds.height)
        band.position = CGPoint(x: -width * 0.4, y: 0)
        CATransaction.commit()
        // motion: allow the sweep is the shimmer itself; Reduce Motion never mounts it (ShimmerText).
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -width * 0.4
        sweep.toValue = width
        sweep.duration = 1.6
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        // Every row's band at the same place: the phase from the clock.
        sweep.timeOffset = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6)
        band.add(sweep, forKey: "sweep")
    }
}

/// No Mac in this team. Pairing is account based: a Mac signed in to the
/// same account, with iPhone connections allowed, appears by itself, and the
/// phone moves to its team when it comes online. Says which team the phone
/// shows, and offers the team where one of the account's Macs already is.
struct ConnectMacEmptyState: View {
    let email: String?
    /// The team shown, when the account has several.
    let teamName: String?
    /// Another team with one of the account's Macs.
    let elsewhere: (team: Team, mac: MacDevice)?
    let switchTeam: ((String) -> Void)?
    let noMacsForAccount: Bool
    let openAccount: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.colors.label)
                    .accessibilityHidden(true)
                Text("Connect your Mac")
                    .font(theme.type.emptyTitle)
                    .foregroundStyle(theme.colors.label)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                if let teamName {
                    Text("No Macs in \(teamName).")
                        .font(theme.type.rowSubtitle)
                        .foregroundStyle(theme.colors.label2)
                        .multilineTextAlignment(.center)
                        .padding(.top, -8)
                        .padding(.bottom, 20)
                        .accessibilityIdentifier("workspaces.connect-mac.team")
                }
                if let elsewhere, let switchTeam {
                    VStack(spacing: 12) {
                        Text("\(elsewhere.mac.name) is in \(elsewhere.team.name).")
                            .font(theme.type.body)
                            .foregroundStyle(theme.colors.label)
                            .multilineTextAlignment(.center)
                        PrimaryCapsule("Switch to \(elsewhere.team.name)") { switchTeam(elsewhere.team.id) }
                            .accessibilityIdentifier("workspaces.connect-mac.switch")
                    }
                    .padding(.bottom, 28)
                }
                ConnectMacSteps(email: email, onlineMac: nil, noMacsForAccount: noMacsForAccount, openAccount: openAccount)
            }
            .padding(.horizontal, theme.metrics.sideMargin)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical) { height, _ in height * 0.8 }
        }
        .accessibilityIdentifier("workspaces.connect-mac")
    }
}

/// The New Workspace toolbar button. A tap creates a workspace at once with
/// the defaults (the preferred or only Mac, its last-used directory or home,
/// the Mac's default first tab: a terminal). Holding it opens a menu of the
/// other ways to start, as Safari's new-tab button and Notes' compose button
/// do. Only options the Mac's backend supports are listed.
struct NewWorkspaceButton: View, Equatable {
    let creator: WorkspaceCreator
    /// The Mac a tap creates on: the filtered Mac, else the preferred one.
    let target: MacDevice?
    /// The Mac picker is offered only under All Macs; with one Mac
    /// filtered, the filter menu is where the Mac changes.
    let showsMacPicker: Bool
    /// The team's same-name Macs, tagged as the filter menu tags them.
    let sameNames: MacNameDisambiguation
    /// The target Mac's recent directories (`WorkspaceCreator.recentDirectories`),
    /// worked out by the list: the button reads no workspaces itself.
    let recents: [String]
    /// What the backend offers on `target`, and the Macs it can create on (from the list).
    let options: WorkspaceCreationOptions?
    let macs: [MacDevice]
    let create: (NewWorkspaceStart, String?) -> Void

    /// Its values, not `creator` or `create` (actions only).
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.target == b.target && a.showsMacPicker == b.showsMacPicker && a.sameNames == b.sameNames && a.recents == b.recents
            && a.options == b.options && a.macs == b.macs
    }
    /// Open Folder…: the typed path, and why the last one was refused.
    @State private var openingFolder = false
    @State private var folderText = ""
    @State private var folderRefusal: String?

    func displayName(_ mac: MacDevice) -> String { sameNames.displayName(mac) }

    var body: some View {
        Menu {
            menu
        } label: {
            Label("New Workspace", systemImage: "square.and.pencil")
        } primaryAction: {
            create(.terminal, nil)
        }
        .disabled(target == nil)
        .alert("Open Folder", isPresented: $openingFolder) {
            TextField("~/code/project", text: $folderText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("workspaces.openFolder.path")
            Button("Cancel", role: .cancel) {}
            Button("Open") { openFolder() }
                .disabled(WorkspaceFolderPath(folderText) == nil)
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(target.map { "The new workspace's terminal opens in this folder on \(displayName($0))." } ?? "")
        }
        .alert("Can't open this folder", isPresented: Binding(get: { folderRefusal != nil }, set: { if !$0 { folderRefusal = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderRefusal ?? "")
        }
        .accessibilityIdentifier("workspaces.new")
        .accessibilityHint(target.map { "Creates a workspace on \(displayName($0))" } ?? "")
    }

    @ViewBuilder private var menu: some View {
        if let mac = target, let options {
            if macs.count > 1 || !showsMacPicker {
                Section("On \(displayName(mac))") { starts(options) }
            } else {
                Section { starts(options) }
            }
            if !recents.isEmpty {
                Section("Recent Directories") {
                    ForEach(recents, id: \.self) { directory in
                        Button {
                            create(.terminal, directory)
                        } label: {
                            Label {
                                Text(Self.folderName(directory))
                                Text(directory)
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                    }
                }
            }
            if options.agents.contains(""), !recents.isEmpty {
                // The Mac's New Agent Chat over Home: a workspace whose only tab is the
                // chat, in one of the Mac's workspace folders.
                Section("New Agent Chat") {
                    ForEach(recents, id: \.self) { directory in
                        Button {
                            create(.agent(""), directory)
                        } label: {
                            Label {
                                Text(Self.folderName(directory))
                                Text(directory)
                            } icon: {
                                Image(systemName: "sparkle")
                            }
                        }
                        .accessibilityIdentifier("workspaces.newAgentChat.\(Self.folderName(directory))")
                    }
                }
            }
            if options.directories {
                Section {
                    // The Mac's Open Folder… (⌘O): a typed path, since a phone browses no Mac folders.
                    Button("Open Folder…", systemImage: "folder.badge.plus") {
                        folderText = ""
                        openingFolder = true
                    }
                    .accessibilityIdentifier("workspaces.openFolder")
                }
            }
            if showsMacPicker && macs.count > 1 {
                Section {
                    Picker(selection: Binding(get: { mac.id }, set: { creator.prefer(macID: $0) })) {
                        ForEach(macs) { Text(displayName($0)).tag($0.id) }
                    } label: {
                        Label("Mac", systemImage: "desktopcomputer")
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    @ViewBuilder private func starts(_ options: WorkspaceCreationOptions) -> some View {
        Button("New Workspace", systemImage: "apple.terminal") { create(.terminal, nil) }
        ForEach(options.agents.filter { !$0.isEmpty }, id: \.self) { harness in
            Button("New \(Self.agentName(harness)) Workspace", systemImage: "sparkle") { create(.agent(harness), nil) }
        }
        if options.browser {
            Button("New Browser Workspace", systemImage: "globe") { create(.browser, nil) }
        }
    }

    static func agentName(_ harness: String) -> String {
        switch harness {
        case "claude": "Claude"
        case "codex": "Codex"
        default: harness.prefix(1).uppercased() + harness.dropFirst()
        }
    }

    private func openFolder() {
        guard let folder = WorkspaceFolderPath(folderText), let mac = target else { return }
        if let refusal = folder.refusal(macName: displayName(mac)) {
            folderRefusal = refusal
            return
        }
        create(.terminal, folder.path)
    }

    static func folderName(_ directory: String) -> String {
        directory == "~" ? "Home" : (directory as NSString).lastPathComponent
    }
}

#endif
