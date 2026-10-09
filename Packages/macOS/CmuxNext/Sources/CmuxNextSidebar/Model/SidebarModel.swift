public import CoreGraphics
public import CmuxNextDesign
import Foundation
public import Observation

/// Input and UI state for one window's sidebar.
///
/// The App layer fills `sections` from daemon state (one machine section per
/// daemon, plus pinned) and sets `onIntent` to forward intents to the owning
/// daemon. Without an `onIntent` handler, intents apply locally, which is how
/// the mock runs standalone.
@Observable @MainActor
public final class SidebarModel {
    /// Pinned area first (optional), then one section per machine.
    public var sections: [SidebarSection]
    /// Multi-selection (Cmd/Shift-click). Always contains `activeWorkspaceID`
    /// when that is set.
    public var selection: Set<WorkspaceID> = []
    /// The window's one sidebar selection (SIDEBAR-SELECTION-ONE-MODEL): a
    /// top-section item while the window shows its page, else the shown
    /// workspace. The App derives it from the window state; the one
    /// highlight, stepping and numbering read it.
    public var selectedItem: SidebarItem?
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
    public var transientTopItems: [SidebarTransientItem] = []

    /// The section that draws `transientTopItems` first in the top band, or
    /// nil without any (built-in look, no title, one row per item).
    var transientTopSection: LayoutSection? {
        transientTopItems.isEmpty ? nil : LayoutSection(id: LayoutSectionID(LayoutItemID.transientPrefix + "top"), showsTitle: false,
                                                        region: .top, look: .builtIn, items: transientTopItems.map(\.item))
    }
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
    /// The card stack above the bottom band (R114): update, announcements.
    public var cards: [SidebarCard] = []
    /// The staged update card above the footer (UPDATE-CARD): set by the App
    /// only while an update is staged or installing; nil shows nothing.
    public var updateCard: SidebarUpdateCard?
    /// The window shows a full-page destination: the footer band shows Back
    /// (`onBack`) in its place.
    public var showsBack = false
    /// Back in the footer: return to where the window was.
    @ObservationIgnored public var onBack: (() -> Void)?
    /// The "Did you know" card (BOTTOM-LEFT-CARDS K1), shown only while
    /// ``updateCard`` and ``updatedCard`` are nil.
    public var tipCard: SidebarTipCard?
    /// The "cmux Updated!" card (cx-7py7), shown only while ``updateCard`` is nil.
    public var updatedCard: SidebarUpdatedCard?
    /// A card's click, button or dismiss.
    @ObservationIgnored public var onCardAction: ((String, SidebarCardAction) -> Void)?
    /// Whether each workspace expands to show its intra-workspace tabs.
    public var showWorkspaceTabs = false
    /// The workspaces whose disclosure hid their tabs: window view state.
    public var collapsedWorkspaces: Set<WorkspaceID> = []
    /// What workspace rows show (`sidebar.workspaceRow.*`).
    public var workspaceRow = WorkspaceRowPreferences.defaults
    /// The workspace list is hidden (`sidebar.showProjects` off).
    public var hidesWorkspaces = false
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
    /// The sections another space shows (R99: the page beside the current
    /// one during a horizontal swipe). Read when a swipe reaches that page.
    @ObservationIgnored public var spaceSections: ((ProfileKey) -> [SidebarSection])?
    /// Called on every presentation change (the App moves focus out of a
    /// hiding sidebar and persists the window state).
    @ObservationIgnored public var onPresentationChange: ((SidebarPresentation) -> Void)?

    public init(sections: [SidebarSection] = [], activeWorkspaceID: WorkspaceID? = nil) {
        self.sections = sections
        collapsedSections = Set(sections.filter(\.isCollapsed).map(\.id))
        self.activeWorkspaceID = activeWorkspaceID
        if let activeWorkspaceID { selection = [activeWorkspaceID] }
    }

    public var isHidden: Bool { presentation == .hidden }

    /// Width the sidebar should occupy for the current presentation.
    public var displayWidth: CGFloat {
        switch presentation {
        case .shown: width
        case .hidden: 0
        }
    }

    /// Current filter matches, or nil when not filtering.
    public var filterMatches: Set<WorkspaceID>? { SidebarFilter.matches(filterText, in: sections) }

    public var isFiltering: Bool { filterMatches != nil }

    /// Every workspace in visual order.
    public var allWorkspaces: [SidebarWorkspace] { sections.flatMap(\.workspaces) }
    /// The rows a position-based pick (Cmd+1…9, next/previous sidebar tab,
    /// select first/last, arrow keys) may land on: every row but
    /// placeholders, which are no workspace yet.
    public var selectableWorkspaces: [SidebarWorkspace] { allWorkspaces.filter { $0.rowState != .placeholder } }

    public func workspace(_ id: WorkspaceID) -> SidebarWorkspace? { SidebarEdits.workspace(id, in: sections) }

    public func group(_ id: GroupID) -> SidebarGroup? {
        guard let (s, n) = SidebarEdits.locateGroup(id, in: sections),
              case let .group(group) = sections[s].nodes[n] else { return nil }
        return group
    }

    public func section(_ id: SectionID) -> SidebarSection? { sections.first { $0.id == id } }

    /// Selected ids in visual order.
    public var orderedSelection: [WorkspaceID] { SidebarEdits.treeOrder(selection, in: sections) }

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
            if !selection.contains(id) { selection = [id] }
        case .selectTab, .moveTab:
            break
        case let .closeGroup(id):
            let ids = group(id)?.workspaces.map(\.id) ?? []
            SidebarEdits.apply(intent, to: &sections)
            dropClosed(Set(ids))
        case let .close(ids):
            SidebarEdits.apply(intent, to: &sections)
            dropClosed(Set(ids))
        case let .switchProfile(id):
            activeProfileID = id
        case .activateItem, .installUpdate, .setAutomaticUpdates, .openUpdateLink, .dropOnLayoutSection, .tryTip, .dismissTip,
             .openWhatsNew, .shareCmux, .dismissUpdated:
            break
        case let .layout(op):
            if case .success(let next) = SidebarLayoutReducer.reduce(layout, op) { layout = next }
        case let .toggleLayoutSection(id):
            if collapsedLayoutSections.remove(id) == nil { collapsedLayoutSections.insert(id) }
        case let .toggleCollapse(.section(id)):
            let collapse = !(section(id)?.isCollapsed ?? collapsedSections.contains(id))
            if collapse { collapsedSections.insert(id) } else { collapsedSections.remove(id) }
            setSections(sections)
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
        var shown = new
        for index in shown.indices {
            let collapsed = collapsedSections.contains(shown[index].id)
            if shown[index].isCollapsed != collapsed { shown[index].isCollapsed = collapsed }
        }
        if sections != shown { sections = shown }
    }

    /// Clears closed workspaces from the selection and picks a new active one.
    private func dropClosed(_ closed: Set<WorkspaceID>) {
        selection.subtract(closed)
        if let active = activeWorkspaceID, closed.contains(active) {
            activeWorkspaceID = selection.first ?? allWorkspaces.first?.id
            if let next = activeWorkspaceID { selection.insert(next) }
        }
    }

    // MARK: Selection (UI-local)

    /// A placeholder row (a machine still connecting) is never selected,
    /// renamed, dragged or shown.
    public func isPlaceholder(_ id: WorkspaceID) -> Bool { workspace(id)?.rowState == .placeholder }

    /// Plain click: select only `id` and activate it.
    public func click(_ id: WorkspaceID) {
        guard !isPlaceholder(id) else { return }
        selection = [id]
        send(.select(id))
    }

    /// Cmd-click: toggle `id` in the selection without changing the active
    /// workspace, unless it is the only selected item.
    public func toggleSelection(_ id: WorkspaceID) {
        guard !isPlaceholder(id) else { return }
        if selection.contains(id) {
            guard selection.count > 1 else { return }
            selection.remove(id)
            if activeWorkspaceID == id, let next = orderedSelection.first { send(.select(next)) }
        } else {
            selection.insert(id)
        }
    }

    /// Shift-click: select the visual range from the active workspace to `id`.
    public func extendSelection(to id: WorkspaceID, visibleOrder: [WorkspaceID]) {
        guard !isPlaceholder(id) else { return }
        guard let anchor = activeWorkspaceID,
              let a = visibleOrder.firstIndex(of: anchor),
              let b = visibleOrder.firstIndex(of: id) else {
            click(id)
            return
        }
        selection = Set(visibleOrder[min(a, b)...max(a, b)])
    }

    /// Arrow-key navigation over the visible rows.
    public func moveActive(by delta: Int, extending: Bool, visibleOrder: [WorkspaceID]) {
        guard !visibleOrder.isEmpty else { return }
        let current = activeWorkspaceID.flatMap { visibleOrder.firstIndex(of: $0) }
        let next = current.map { max(0, min(visibleOrder.count - 1, $0 + delta)) } ?? (delta > 0 ? 0 : visibleOrder.count - 1)
        let id = visibleOrder[next]
        guard !isPlaceholder(id) else { return }
        if extending {
            selection.insert(id)
            activeWorkspaceID = id
            send(.select(id))
        } else {
            click(id)
        }
    }

    /// Cmd-Opt-Up/Down: move the selection one slot. Returns false at a
    /// boundary or while filtering.
    @discardableResult
    public func moveSelection(_ direction: KeyboardReorder.Direction) -> Bool {
        guard !isFiltering else { return false }
        let ids = orderedSelection
        guard let position = KeyboardReorder.target(moving: ids, direction: direction, in: sections) else { return false }
        send(.reorder(ids, to: position))
        return true
    }

    /// The `sidebar.*` settings that shape the workspace list.
    func applyListPreferences(_ preferences: SidebarSectionsPreferences) {
        showWorkspaceTabs = preferences.showWorkspaceTabs
        workspaceRow = preferences.workspaceRow
        hidesWorkspaces = !preferences.showProjects
        groupsByComputer = preferences.groupsByComputer
    }

    /// The disclosure on a workspace row: hide its listed tabs, or list them again.
    public func toggleWorkspaceTabs(_ id: WorkspaceID) {
        if collapsedWorkspaces.remove(id) == nil { collapsedWorkspaces.insert(id) }
    }

    /// The list layout's options that come from the model.
    func listOptions() -> SidebarLayoutOptions {
        var o = SidebarLayoutOptions()
        o.filterMatches = filterMatches
        o.showWorkspaceTabs = showWorkspaceTabs
        o.collapsedWorkspaces = collapsedWorkspaces
        o.workspaceRow = workspaceRow
        o.flattensMachines = !groupsByComputer
        o.now = Calendar.current.startOfDay(for: Date())
        o.hidesWorkspaces = hidesWorkspaces
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
        presentation = presentation == .hidden ? .shown : .hidden
    }
}

/// A client-only top item and its look (`SidebarModel.transientTopItems`).
public nonisolated struct SidebarTransientItem: Hashable, Sendable {
    public var item: LayoutItem
    public var info: SidebarItemInfo

    /// `id` must carry the `client.` prefix (`LayoutItemID.isTransient`).
    public init(id: LayoutItemID, info: SidebarItemInfo) {
        item = LayoutItem(id: id, ref: LayoutItemRef(kind: "client", value: id.rawValue))
        self.info = info
    }
}
