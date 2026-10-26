public import CoreGraphics
public import CmuxNextDesign
public import Foundation
public import Observation

/// Input and UI state for one window's sidebar.
///
/// The App layer fills `sections` from daemon state (one machine section per
/// daemon, plus pinned) and sets `onIntent` to forward intents to the owning
/// daemon. Without an `onIntent` handler, intents apply locally, which is how
/// the mock runs standalone.
@Observable @MainActor
public final class SidebarModel {
    /// Pinned area first (optional), then one section per machine. A set is
    /// a structural change (`sectionsRevision` moves, the list reloads); a row
    /// content change goes through `patchWorkspaces` and reloads nothing.
    public var sections: [SidebarSection] {
        get {
            access(keyPath: \.sections)
            return storedSections
        }
        set {
            // A group's indent comes only from the groups this list holds (`resolvingGroupDepths`).
            let newValue = newValue.map { $0.resolvingGroupDepths() }
            // An unchanged set is no structural change (an intent that edits nothing).
            guard newValue != storedSections else { return }
            withMutation(keyPath: \.sections) {
                storedSections = newValue
                sectionsRevision &+= 1
                structureRevision = sectionsRevision
            }
            rowIndex = nil
            groupPaths = nil
        }
    }
    @ObservationIgnored private var storedSections: [SidebarSection] { didSet { contentRevision &+= 1 } }
    /// Moves on every write of the rows: a structural set, a fold, and a row patch (`patchWorkspaces`), which
    /// `sectionsRevision` does not count. A reader that saves what the rows show (the sidebar snapshot) compares it
    /// instead of every row.
    @ObservationIgnored public private(set) var contentRevision: UInt64 = 0
    /// Moves on every structural set of `sections`: readers compare it instead
    /// of the rows themselves (one counter, not a deep compare of 1,000 rows).
    @ObservationIgnored public private(set) var sectionsRevision: UInt64 = 0
    /// `sectionsRevision`, read so a tracked reader hears the next structural set.
    public var observedSectionsRevision: UInt64 {
        access(keyPath: \.sections)
        return sectionsRevision
    }
    /// `sectionsRevision` at the last structural set: a group's fold (`setGroupCollapsed`) moves
    /// `sectionsRevision` (caches keyed on it rebuild) but not this, so the sidebar draws a fold by
    /// splicing its rows (`onGroupFolded`) instead of laying the whole list out again.
    @ObservationIgnored public private(set) var structureRevision: UInt64 = 0
    /// `structureRevision`, read so a tracked reader hears the next structural set.
    public var observedStructureRevision: UInt64 {
        access(keyPath: \.sections)
        return structureRevision
    }
    /// Where each group sits in `sections` (section, node); built on the first fold after a set.
    @ObservationIgnored var groupPaths: [GroupID: (section: Int, node: Int)]?
    /// Told each group `setGroupCollapsed` folded or opened (the list splices that group's rows).
    @ObservationIgnored public var onGroupFolded: ((GroupID) -> Void)?

    /// Folds (`collapsed`) or opens group `id` at once, as view state (state-ownership-DESIGN.md): the one group in
    /// place, no structural set, then `onGroupFolded`, so it costs the group's rows. False when no listed group has `id`.
    @discardableResult
    public func setGroupCollapsed(_ id: GroupID, _ collapsed: Bool) -> Bool {
        if groupPaths == nil {
            var paths: [GroupID: (section: Int, node: Int)] = [:]
            for (s, section) in storedSections.enumerated() {
                for (n, node) in section.nodes.enumerated() {
                    if case let .group(group) = node, paths[group.id] == nil { paths[group.id] = (s, n) }
                }
            }
            groupPaths = paths
        }
        guard let (s, n) = groupPaths?[id], case var .group(group) = storedSections[s].nodes[n] else { return false }
        guard group.isCollapsed != collapsed else { return true }
        group.isCollapsed = collapsed
        revealedMembers[id] = nil
        storedSections[s].nodes[n] = .group(group)
        sectionsRevision &+= 1
        onGroupFolded?(id)
        return true
    }

    /// The section that lists group `id` (O(1) after a fold built `groupPaths`).
    func groupSection(_ id: GroupID) -> SidebarSection? {
        if let (s, _) = groupPaths?[id] { return storedSections[s] }
        return SidebarEdits.locateGroup(id, in: storedSections).map { storedSections[$0.section] }
    }
    /// `sectionsRevision` at the user's last keyboard move (never a drop): the next structural set may scroll to the moved
    /// active row; nil, none waits. Changes from others never move the view (DESIGN.md scroll reveal, cx-ml98q).
    @ObservationIgnored public private(set) var userMoveRevision: UInt64?
    /// Members a collapsed group keeps drawing after the selection left them, until it folds or opens (a click moves no row).
    @ObservationIgnored var revealedMembers: [GroupID: Set<WorkspaceID>] = [:]
    /// The user moved rows: the structural set that shows the move may reveal the active row.
    public func noteUserMove() {
        userMoveRevision = sectionsRevision
        noteUserIntent()
    }
    /// When this app's user last asked for a sidebar change (`noteUserIntent`): only a change
    /// that follows within `userIntentWindow` moves rows on a spring (calm-sidebar-movement).
    @ObservationIgnored var userIntentAt: ContinuousClock.Instant?
    /// The clock `noteUserIntent` reads; tests inject a fixed instant.
    @ObservationIgnored public var userIntentClock: @MainActor () -> ContinuousClock.Instant = { .now }
    /// True once: at the first structural set after the user's move.
    public func takeUserMove() -> Bool {
        guard let mark = userMoveRevision, mark != sectionsRevision else { return false }
        userMoveRevision = nil
        return true
    }
    /// Where each workspace sits in `sections`; rebuilt on the first patch after a set.
    @ObservationIgnored var rowIndex: SidebarRowIndex?
    /// `workspaceOrder` and the `sectionsRevision` it was built at.
    @ObservationIgnored private var workspaceOrderCache: (revision: UInt64, order: SidebarWorkspaceOrder)?
    /// The order this window lists its workspaces in, with each one's position and neighbours in O(1)
    /// (``SidebarWorkspaceOrder``). Built once per structural change of the rows (a move, a group change, a create
    /// or close), so every reader after it costs no walk of the rows; a row's content patch keeps it.
    public var workspaceOrder: SidebarWorkspaceOrder {
        access(keyPath: \.sections)
        if let cached = workspaceOrderCache, cached.revision == sectionsRevision { return cached.order }
        SidebarPerfCounters.add(.orderBuilds)
        let order = SidebarWorkspaceOrder(storedSections)
        workspaceOrderCache = (sectionsRevision, order)
        return order
    }
    /// `itemOrder` and the inputs it was made from.
    @ObservationIgnored var itemOrderCache: (inputs: SidebarItemOrderInputs, order: SidebarItemOrder)?
    /// Told the workspaces `patchWorkspaces` changed in place (the list reconfigures their rows).
    @ObservationIgnored public var onRowsPatched: (([SidebarWorkspace]) -> Void)?
    /// The workspace rows as the list draws them, top to bottom (its folder sort and filter applied; empty with no list).
    @ObservationIgnored public var drawnWorkspaceOrder: () -> [WorkspaceID] = { [] }
    /// Multi-selection (Cmd/Shift-click). Always contains `activeWorkspaceID`
    /// when that is set.
    public var selection: Set<WorkspaceID> = []
    /// Where a Shift range starts: the row last clicked, Cmd-clicked in or
    /// moved to without Shift. Shift+Arrow and Shift-click select from it to
    /// the new row, so going back shrinks the range.
    @ObservationIgnored var selectionAnchor: WorkspaceID?
    /// The moving end of a Shift range (the row last Shift-clicked or
    /// Shift-arrowed to): the next Shift+Arrow steps from it, as in Finder.
    @ObservationIgnored var selectionExtent: WorkspaceID?
    /// Every workspace on screen in this window, the shown one too (`sidebar.multiView`): their rows draw a
    /// soft fill under the selection's. The App sets it; empty draws nothing extra.
    public var onScreen: Set<WorkspaceID> = []
    /// The window's one sidebar selection (SIDEBAR-SELECTION-ONE-MODEL): a
    /// top-section item while the window shows its page, else the shown
    /// workspace. The App derives it from the window state; the one
    /// highlight, stepping and numbering read it.
    ///
    /// The focused workspace is always listed (sidebar-focused-visible): a
    /// new workspace selection opens the collapsed sections that hide it
    /// (`expandSections(hiding:)`), and the list scrolls it into view
    /// (`ListViewport.settle`). Every selection path (a click, Cmd-P, a link,
    /// the CLI, an agent's focus, a new workspace) sets this one property.
    public var selectedItem: SidebarItem? {
        didSet {
            guard selectedItem != oldValue else { return }
            noteLeft(oldValue)
            guard case let .workspace(id)? = selectedItem else { return }
            expandSections(hiding: id)
        }
    }
    /// The workspace shown in the window: the selection when it is a workspace.
    public var activeWorkspaceID: WorkspaceID? {
        get { if case .workspace(let id)? = selectedItem { id } else { nil } }
        set { selectedItem = newValue.map(SidebarItem.workspace) }
    }
    /// Profiles in order (the bar at the bottom center). The bar hides
    /// while there is at most one.
    public var profiles: [SidebarProfile] = []
    /// The profile this window shows.
    public var activeProfileID: ProfileKey?
    /// The section layout to draw (plans/cmux-next/sidebar-sections.md):
    /// the App fills it with the store's document plus pending intents.
    public var layout: SidebarLayoutDocument = .defaults
    /// How layout items draw, by item id. Built-ins without an entry draw
    /// their own title and symbol.
    public var itemInfo: [LayoutItemID: SidebarItemInfo] = [:]
    /// Client-only items above the top band's sections (the What's New item
    /// after an update). Never in `layout`: they cannot be moved, edited or
    /// hidden, and activate like any item (`SidebarIntent.activateItem`).
    /// An item with an anchor (`SidebarTransientItem.after`) draws right after it instead
    /// (`placingTransientItems`): the Channels entry after Home.
    public var transientTopItems: [SidebarTransientItem] = []
    /// The current profile's avatar: the account item draws it as the
    /// profile control (`resolvedItemInfo`; SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2).
    public var profileAvatar: SidebarAvatar?
    /// Apps whose sections and items draw nothing (installed but hidden or
    /// disabled, D55); the App fills it from its one presence rule
    /// (`AppsService.presence`). The layout keeps their places.
    public var suppressedApps: Set<String> = []
    /// Collapsed titled sections: client view state, saved with the window.
    public var collapsedLayoutSections: Set<LayoutSectionID> = [] {
        didSet { if collapsedLayoutSections != oldValue { onCollapsedLayoutSectionsChange?(collapsedLayoutSections) } }
    }
    /// Told the new set when a layout section collapses or expands (the App saves it).
    @ObservationIgnored public var onCollapsedLayoutSectionsChange: ((Set<LayoutSectionID>) -> Void)?
    /// Collapsed top-level sections (Pinned, a machine): client view state,
    /// never sent to a daemon. `setSections` and the section toggle keep
    /// each section's `isCollapsed` equal to it, so the live remap of the
    /// daemon's rows does not expand a section the user collapsed; the
    /// window's sidebar snapshot saves it for the next launch.
    public var collapsedSections: Set<SectionID> = []
    /// Search field contents. Non-empty text filters rows and disables drag.
    public var filterText = ""
    /// The staged update card above the footer (UPDATE-CARD): set by the App
    /// only while an update is staged or installing; nil shows nothing.
    public var updateCard: SidebarUpdateCard?
    /// The shared notice card (the update status or the "Did you know"
    /// tip), shown only while ``updateCard`` and ``updatedCard`` are nil.
    public var noticeCard: SidebarNoticeCard?
    /// The "cmux Updated!" card (cx-7py7), shown only while ``updateCard`` is nil.
    public var updatedCard: SidebarUpdatedCard?
    /// The Now Playing card (cx-ouoxo), shown only while ``updateCard`` is nil.
    public var nowPlaying: SidebarNowPlaying?
    /// Whether each workspace expands to show its intra-workspace tabs.
    public var showWorkspaceTabs = false
    /// The workspaces whose disclosure hid their tabs: window view state.
    public var collapsedWorkspaces: Set<WorkspaceID> = []
    /// What workspace rows show (`sidebar.workspaceRow.*`).
    public var workspaceRow = WorkspaceRowPreferences.defaults
    /// How rows show their state (`SidebarRowBadgeStyle`); nil follows the Debug setting.
    public var rowBadgeStyle: SidebarRowBadgeStyle?
    /// The workspace list is hidden (`sidebar.showProjects` off).
    public var hidesWorkspaces = false
    /// Minimal mode (`sidebar.minimal`): rows draw only icon, name and marks.
    public var minimal = false
    /// `sidebar.style`: the standard sidebar or the thin rail (plans/cmux-next/minimal-sidebar.md).
    public var style: SidebarLayoutStyle = .standard
    /// The rail's full sidebar is open over the content (`SidebarRailPeek`); window view state.
    public var isRailOpen = false
    /// Expanded rows (`sidebar.density`), unless minimal.
    public var expanded = false
    /// Row badges draw each state apart (`sidebar.detailedStatusIcons`), not Working or Ready only.
    public var detailedStatus = false
    /// Rows show when they last changed (`sidebar.showTimestamps`, off by default).
    public var showsTimestamps = false
    /// `sidebar.showColors`: off, rows and group headers draw no workspace or group color.
    public var showsColors = true
    /// This Mac's rows carry its machine mark too (`sidebar.showLocalMachine`, off by default).
    public var showsLocalMachine = false
    /// What a collapsed group header shows beside its loading spinner
    /// (`sidebar.groupHeader.*`, all off by default; `sidebar.detailedStatusIcons`
    /// adds its members' other states).
    public var groupHeaderDetails = GroupHeaderDetails()
    /// `sidebar.groupBy` and Group by Status's folds and held row (`SidebarModel+Grouping`).
    public var grouping = SidebarGrouping()
    /// `sidebar.groupByComputer`: a header per computer; off, one list.
    public var groupsByComputer = SidebarSectionsPreferences.defaults.groupsByComputer
    /// Machine sections list loose workspaces before groups (a daemon-backed
    /// sidebar: cmux-tui keeps no slot for one after a group), so a drag
    /// never offers a slot past the first group.
    @ObservationIgnored public var ungroupedFirst = false
    /// Shown or hidden. Setting it notifies `onPresentationChange`
    /// synchronously, before any animation, so focus can leave a hiding
    /// sidebar in the same turn.
    public var presentation: SidebarPresentation = .shown {
        didSet { if presentation != oldValue { onPresentationChange?(presentation) } }
    }
    /// Width when shown, clamped to `widthRange`. Hiding keeps it, so the
    /// sidebar comes back at the user's width.
    public var width: CGFloat = Metrics.sidebarWidth {
        didSet {
            let clamped = min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
            if clamped != width { width = clamped }
        }
    }

    public static var widthRange: ClosedRange<CGFloat> { Metrics.sidebarMinWidth...Metrics.sidebarMaxWidth }

    /// Receives every intent. When nil, `send` applies intents locally.
    @ObservationIgnored public var onIntent: ((SidebarIntent) -> Void)?
    /// A workspace's pin state and the Pin/Unpin Workspace action, from the
    /// App (layout tiles or the daemon flag): an expanded row's hover pin.
    @ObservationIgnored public var workspacePin: (isPinned: (WorkspaceID) -> Bool, toggle: (WorkspaceID) -> Void)?
    /// The sections another space shows (R99: the page beside the current
    /// one during a horizontal swipe). Read when a swipe reaches that page.
    @ObservationIgnored public var spaceSections: ((ProfileKey) -> [SidebarSection])?
    /// Called on every presentation change (the App moves focus out of a
    /// hiding sidebar and persists the window state).
    @ObservationIgnored public var onPresentationChange: ((SidebarPresentation) -> Void)?

    public init(sections: [SidebarSection] = [], activeWorkspaceID: WorkspaceID? = nil) {
        storedSections = sections.map { $0.resolvingGroupDepths() }
        collapsedSections = Set(sections.filter(\.isCollapsed).map(\.id))
        self.activeWorkspaceID = activeWorkspaceID
        if let activeWorkspaceID { selection = [activeWorkspaceID] }
    }

    public var isHidden: Bool { presentation == .hidden }

    /// Width the sidebar should occupy for the current presentation.
    public var displayWidth: CGFloat {
        switch presentation {
        case .shown: style == .rail && !isRailOpen ? SidebarRailLayout.Metrics().railWidth : width
        case .hidden: 0
        }
    }

    /// How far the content sits from the sidebar's window edge (before the gutter). The rail's
    /// full sidebar opens over the content, so the content keeps the rail's width beside it.
    public var contentInset: CGFloat {
        switch (presentation, style) {
        case (.hidden, _): 0
        case (.shown, .standard): width
        case (.shown, .rail): SidebarRailLayout.Metrics().railWidth
        }
    }

    /// Current filter matches, or nil when not filtering.
    public var filterMatches: Set<WorkspaceID>? { SidebarFilter.matches(filterText, in: sections) }

    public var isFiltering: Bool { filterMatches != nil }

    /// Drag and keyboard reorder are off while the drawn order is not the
    /// model's: filtering, or grouping by folder. On the sidebar document a
    /// drag moves next to the row it is dropped by (an anchor), so it also
    /// works while filtering.
    public var locksReorder: Bool { (isFiltering && docDrag == nil) || grouping.isGrouped }
    /// The sidebar document's drag half (sidebar-v2 S5), set by the App
    /// while the document is active.
    @ObservationIgnored public var docDrag: SidebarDocDrag?
    /// The favicon at a page icon address, when the App has it (it fetches a missing one); link rows draw it.
    public static var itemFavicon: ((String) -> SidebarFavicon?)?
    /// Posted when favicons arrived: every list draws its link rows again.
    public static let itemFaviconsChanged = Notification.Name("cmux.sidebar.itemFaviconsChanged")

    /// Every workspace in visual order.
    public var allWorkspaces: [SidebarWorkspace] { sections.flatMap(\.workspaces) }
    /// The rows a position-based pick (Cmd+1…9, next/previous sidebar tab,
    /// select first/last, arrow keys) may land on: every row but
    /// placeholders, which are no workspace yet.
    public var selectableWorkspaces: [SidebarWorkspace] { allWorkspaces.filter { !$0.rowState.isPending } }

    public func workspace(_ id: WorkspaceID) -> SidebarWorkspace? { SidebarEdits.workspace(id, in: sections) }

    public func group(_ id: GroupID) -> SidebarGroup? {
        // O(1) once a fold built `groupPaths` (a header click reads its group, then folds it).
        if let (s, n) = groupPaths?[id] {
            access(keyPath: \.sections)
            if case let .group(group) = storedSections[s].nodes[n] { return group }
        }
        guard let (s, n) = SidebarEdits.locateGroup(id, in: sections),
              case let .group(group) = sections[s].nodes[n] else { return nil }
        return group
    }

    public func section(_ id: SectionID) -> SidebarSection? { sections.first { $0.id == id } }

    /// Selected ids in visual order.
    public var orderedSelection: [WorkspaceID] { SidebarEdits.treeOrder(selection, in: sections) }

    /// What a row verb on `id` (Close, Pin, Duplicate, Move Up/Down, from its menu or a key) acts
    /// on: the whole selection, in row order, when `id` is one of two or more selected rows;
    /// otherwise `id` alone.
    public func actionTargets(for id: WorkspaceID) -> [WorkspaceID] {
        selection.count > 1 && selection.contains(id) ? orderedSelection : [id]
    }

    /// What a close of `id` from its menu or a key closes (``actionTargets(for:)``).
    public func closeTargets(for id: WorkspaceID) -> [WorkspaceID] { actionTargets(for: id) }

    // MARK: Intents

    /// Emits an intent to `onIntent`, or applies it locally when unset.
    public func send(_ intent: SidebarIntent) {
        if let onIntent { onIntent(intent) } else { apply(intent) }
    }

    /// Applies an intent to local state. Call from `onIntent` for optimistic
    /// updates before the daemon confirms.
    public func apply(_ intent: SidebarIntent) {
        switch intent {
        case let .select(id):
            activeWorkspaceID = id
            selection = [id]
        case .selectTab, .moveTab:
            break
        case let .closeGroup(id):
            let ids = group(id)?.workspaces.map(\.id) ?? []
            let oldOrder = allWorkspaces.map(\.id)
            SidebarEdits.apply(intent, to: &sections)
            dropClosed(Set(ids), oldOrder: oldOrder)
        case let .close(ids):
            let oldOrder = allWorkspaces.map(\.id)
            SidebarEdits.apply(intent, to: &sections)
            dropClosed(Set(ids), oldOrder: oldOrder)
        case let .switchProfile(id):
            activeProfileID = id
        case .activateItem, .installUpdate, .setAutomaticUpdates, .openUpdateLink, .openUpdateChanges, .dropOnLayoutSection, .noticeAction, .dismissNotice,
             .openWhatsNew, .dismissUpdated, .nowPlaying, .hideNowPlayingCard, .toggleWorkspaceAudio, .addItems:
            break
        case let .layout(op):
            if case .success(let next) = SidebarLayoutReducer.reduce(layout, op) { layout = next }
        case let .toggleLayoutSection(id):
            if collapsedLayoutSections.remove(id) == nil { collapsedLayoutSections.insert(id) }
        case let .toggleCollapse(.group(id)):
            // View state: one group's rows, no structural set (`setGroupCollapsed`).
            if let collapsed = group(id)?.isCollapsed { setGroupCollapsed(id, !collapsed) }
        case let .toggleCollapse(.section(id)):
            let collapse = !(section(id)?.isCollapsed ?? collapsedSections.contains(id))
            if collapse { collapsedSections.insert(id) } else { collapsedSections.remove(id) }
            sections = Self.folding(sections, collapsedSections)
        case let .reorderProfile(id, index):
            guard let from = profiles.firstIndex(where: { $0.id == id }),
                  let to = ProfileBarLogic.finalIndex(from: from, insertion: index, count: profiles.count) else { return }
            profiles.insert(profiles.remove(at: from), at: to)
        case .newProfile:
            let id = ProfileKey("prof_" + UUID().uuidString.lowercased())
            profiles.append(SidebarProfile(id: id, name: Strings.newProfileName))
            activeProfileID = id
        default:
            SidebarEdits.apply(intent, to: &sections)
        }
    }

    /// Shows `new` (the App's mapping of daemon state) with this window's
    /// collapsed sections applied; assigns only when something changed.
    public func setSections(_ new: [SidebarSection]) {
        SidebarPerfCounters.add(.sectionSets) // each set arranges and compares every row
        // The sidebar document places every item: links in machine lists, Pinned and custom groups in their own list sections.
        let shown = docDrag.flatMap { drag in SidebarDocStore.current?.shown.map { $0.arrange(new, drag: drag) } } ?? new
        sections = Self.folding(shown, collapsedSections) // the setter skips an unchanged list
    }

    /// Row content of listed workspaces (status, title, unread, progress, icon), written in place with no structural
    /// change, then told to `onRowsPatched`; a row this window does not list is skipped. False, writing nothing, when the
    /// change moves rows (filter, folder buckets, listed tabs); the caller then sets the sections.
    public func patchWorkspaces(_ rows: [SidebarWorkspace]) -> Bool {
        guard !rows.isEmpty else { return true }
        if rowIndex == nil { rowIndex = SidebarRowIndex(storedSections) }
        guard let index = rowIndex else { return false }
        // A filter may match or drop a listed row: shown again; a row this window does not list changes nothing.
        guard filterText.isEmpty else { return !rows.contains { !index.paths(of: $0.id).isEmpty } }
        var patched: [SidebarWorkspace] = []
        var writes: [(SidebarRowIndex.Path, SidebarWorkspace)] = []
        for var row in rows {
            let paths = index.paths(of: row.id)
            guard let path = paths.first else { continue }
            let old = SidebarRowIndex.workspace(at: path, in: storedSections)
            row.rowState = old.rowState
            row.machineID = old.machineID
            row.isArchived = old.isArchived // the document's, set by `arrange`; the feed does not know it
            guard row != old else { continue }
            guard !movesRows(from: old, to: row) else { return false }
            for path in paths {
                // Each listed copy keeps its own row state (a saved stale row beside the live one).
                var copy = row
                copy.rowState = SidebarRowIndex.workspace(at: path, in: storedSections).rowState
                writes.append((path, copy))
            }
            patched.append(row)
        }
        for (path, row) in writes { SidebarRowIndex.set(row, at: path, in: &storedSections) }
        if !patched.isEmpty { onRowsPatched?(patched) }
        return true
    }

    /// Whether these sections list workspace `id`: O(1) through `rowIndex`
    /// (built once per structural set), never a walk of every row.
    public func lists(_ id: WorkspaceID) -> Bool { !listedPaths(of: id).isEmpty }

    /// Whether `id` sits in a collapsed group: the list draws its row only while it is active or revealed.
    func isInCollapsedGroup(_ id: WorkspaceID) -> Bool { collapsedGroup(of: id) != nil }
    func collapsedGroup(of id: WorkspaceID) -> GroupID? {
        for path in listedPaths(of: id) where path.member != nil {
            if case let .group(group) = storedSections[path.section].nodes[path.node], group.isCollapsed { return group.id }
        }
        return nil
    }

    /// Opens the collapsed sections that hide workspace `id` (a machine or
    /// Pinned section, a document section), so the focused workspace has a
    /// row. A collapsed group stays closed: it draws its active member as its
    /// one row (`SidebarLayout.make`). Called on a selection change only, so
    /// the user can still collapse the section the focused workspace is in.
    func expandSections(hiding id: WorkspaceID) {
        var sectionIDs: Set<SectionID> = [], layoutIDs: Set<LayoutSectionID> = []
        for path in listedPaths(of: id) {
            let section = storedSections[path.section]
            if collapsedSections.contains(section.id) || section.isCollapsed { sectionIDs.insert(section.id) }
            if case let .custom(custom) = section.kind, collapsedLayoutSections.contains(LayoutSectionID(custom.id)) {
                layoutIDs.insert(LayoutSectionID(custom.id))
            }
        }
        if !layoutIDs.isEmpty { collapsedLayoutSections.subtract(layoutIDs) }
        guard !sectionIDs.isEmpty else { return }
        collapsedSections.subtract(sectionIDs)
        sections = Self.folding(sections, collapsedSections)
    }

    private func listedPaths(of id: WorkspaceID) -> [SidebarRowIndex.Path] {
        if rowIndex == nil { rowIndex = SidebarRowIndex(storedSections) }
        return rowIndex?.paths(of: id) ?? []
    }

    /// Clears closed workspaces from the selection and picks a new active one.
    private func dropClosed(_ closed: Set<WorkspaceID>, oldOrder: [WorkspaceID]) {
        let oldActive = activeWorkspaceID
        selection.subtract(closed)
        if let oldActive, closed.contains(oldActive) {
            let surviving = allWorkspaces.map(\.id)
            let next = FocusAfterClose.workspace(shown: oldActive, old: oldOrder, surviving: surviving, orders: [drawnWorkspaceOrder()])
            activeWorkspaceID = next
            selection = next.map { [$0] } ?? []
        }
    }

    /// Cmd-Opt-Up/Down: move the selection one slot. Returns false at a
    /// boundary or while filtering.
    @discardableResult
    public func moveSelection(_ direction: KeyboardReorder.Direction) -> Bool {
        move(orderedSelection, direction)
    }

    /// Move Up/Down on row `id`: moves ``actionTargets(for:)`` one slot as one block, as
    /// Cmd-Opt-Up/Down does. Returns false at a boundary or while reordering is locked.
    @discardableResult
    public func moveActionTargets(of id: WorkspaceID, _ direction: KeyboardReorder.Direction) -> Bool {
        move(actionTargets(for: id), direction)
    }

    private func move(_ ids: [WorkspaceID], _ direction: KeyboardReorder.Direction) -> Bool {
        guard !locksReorder, !ids.isEmpty else { return false }
        if isFiltering, let docDrag {
            guard docDrag.keyboardMove(ids, up: direction == .up, model: self) else { return false }
            noteUserMove()
            return true
        }
        guard let position = KeyboardReorder.target(moving: ids, direction: direction, in: sections) else { return false }
        noteUserMove()
        send(.reorder(ids, to: position))
        return true
    }

    /// The `sidebar.*` settings that shape the workspace list.
    func applyListPreferences(_ preferences: SidebarSectionsPreferences) {
        // Minimal mode lists no tab rows under a workspace.
        showWorkspaceTabs = preferences.showWorkspaceTabs && !preferences.minimal
        workspaceRow = preferences.workspaceRow
        (minimal, expanded) = (preferences.minimal, preferences.density == .expanded)
        detailedStatus = preferences.detailedStatusIcons
        showsTimestamps = preferences.showTimestamps
        showsColors = preferences.showColors
        showsLocalMachine = preferences.showLocalMachine
        groupHeaderDetails = GroupHeaderDetails(memberCount: preferences.groupHeaderMemberCount,
                                                unreadCount: preferences.groupHeaderUnreadCount)
        hidesWorkspaces = !preferences.showProjects
        grouping.by = preferences.groupBy
        groupsByComputer = preferences.groupsByComputer
        if style != preferences.style { (style, isRailOpen) = (preferences.style, false) }
    }

    /// The disclosure on a workspace row: hide its listed tabs, or list them again.
    public func toggleWorkspaceTabs(_ id: WorkspaceID) {
        if collapsedWorkspaces.remove(id) == nil { collapsedWorkspaces.insert(id) }
    }

    /// The list layout's options that come from the model.
    func listOptions() -> SidebarLayoutOptions {
        var o = SidebarLayoutOptions()
        o.filterMatches = filterMatches
        // Workspaces as tabs lists no tab rows under a workspace, as minimal mode.
        (o.workspacesAsTabs, o.foldsDone, o.rowLimit) = (SidebarTunables.workspacesAsTabs.value, SidebarTunables.doneFold.value, SidebarTunables.rowLimit)
        o.showWorkspaceTabs = showWorkspaceTabs && !o.workspacesAsTabs
        o.collapsedWorkspaces = collapsedWorkspaces
        o.activeWorkspaceID = activeWorkspaceID
        // A group opened by a structural set (another client) forgets its revealed members.
        revealedMembers = revealedMembers.filter { group($0.key)?.isCollapsed == true }
        o.revealedWorkspaces = revealedMembers
        o.workspaceRow = workspaceRow
        (o.minimal, o.expanded) = (minimal, expanded)
        o.detailedStatus = detailedStatus
        o.showsTimestamps = showsTimestamps
        o.showsColors = showsColors
        o.flattensMachines = !groupsByComputer
        if o.flattensMachines {
            for section in sections {
                guard let machine = section.machine, machine.kind != .local,
                      let status = Strings.attentionStatus(machine.status) else { continue }
                o.machineStatusLabels[machine.id] = status
            }
        }
        let listed = sections.compactMap(\.machine)
        if Set(listed.map(\.id)).count > 1 {
            o.machines = Dictionary(listed.filter { $0.kind != .local || showsLocalMachine }.map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        }
        o.now = Calendar.current.startOfDay(for: Date())
        o.hidesWorkspaces = hidesWorkspaces
        o.grouping = settledGrouping()
        return o
    }

    // MARK: Presentation

    /// Next (+1) or previous (-1) profile, clamped at the ends. Returns
    /// false when there is none that way.
    @discardableResult
    public func stepProfile(by delta: Int) -> Bool {
        guard let target = ProfileBarLogic.step(from: activeProfileID, by: delta, in: profiles.map(\.id)) else { return false }
        send(.switchProfile(target))
        return true
    }

    /// Toggle Sidebar: fully shown at `width`, or fully hidden.
    public func toggle() {
        // The rail (`sidebar.style` = rail): the toggle opens the full sidebar over the content and
        // closes it back to the rail (Lawrence 2026-10-21: the full sidebar opens from the toggle, not on hover).
        if style == .rail, presentation == .shown {
            isRailOpen.toggle()
            return
        }
        presentation = presentation == .hidden ? .shown : .hidden
    }
}
