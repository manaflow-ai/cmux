public import CoreGraphics
import CmuxNextDesign
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
    /// The workspace shown in the window.
    public var activeWorkspaceID: WorkspaceID?
    /// Search field contents. Non-empty text filters rows and disables drag.
    public var filterText = ""
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
    /// Called on every presentation change (the App moves focus out of a
    /// hiding sidebar and persists the window state).
    @ObservationIgnored public var onPresentationChange: ((SidebarPresentation) -> Void)?

    public init(sections: [SidebarSection] = [], activeWorkspaceID: WorkspaceID? = nil) {
        self.sections = sections
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
        case let .closeGroup(id):
            let ids = group(id)?.workspaces.map(\.id) ?? []
            SidebarEdits.apply(intent, to: &sections)
            dropClosed(Set(ids))
        case let .close(ids):
            SidebarEdits.apply(intent, to: &sections)
            dropClosed(Set(ids))
        default:
            SidebarEdits.apply(intent, to: &sections)
        }
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

    /// Plain click: select only `id` and activate it.
    public func click(_ id: WorkspaceID) {
        selection = [id]
        send(.select(id))
    }

    /// Cmd-click: toggle `id` in the selection without changing the active
    /// workspace, unless it is the only selected item.
    public func toggleSelection(_ id: WorkspaceID) {
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

    // MARK: Presentation

    /// Toggle Sidebar: fully shown at `width`, or fully hidden.
    public func toggle() {
        presentation = presentation == .hidden ? .shown : .hidden
    }
}
