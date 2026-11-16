/// The check of the sidebar's first frame.
///
/// The rule for a first frame: a new thing (here a window, with its sidebar) is put on the screen only after one
/// synchronous pass wrote each model that its first frame reads. A task only follows changes after that; it is
/// never the first writer. With no value yet, a place draws one of the designed states below.
///
/// The owner of a model runs its pass in the turn that makes the sidebar, and the window's order-in asserts
/// `isComplete` (`SidebarSectionsPass.completeFirstFrame`). This type checks the band's items; the rows
/// of the workspace list have their own pass.
public nonisolated struct SidebarFirstFrame: Sendable {
    /// The one list of the states the sidebar may draw in the place of a value that it does not have. A state that
    /// is not on this list is a fault: add a case here, with the place that draws it, before a view draws a new one.
    public nonisolated enum DesignedState: Hashable, Sendable, CaseIterable {
        /// A row of a machine that still connects, with nothing saved: a static bar (`SidebarRowState.placeholder`).
        case loadingRow
        /// A row from saved or launch data: its title and icon as last known, no live status (`SidebarRowState.stale`).
        case savedRow
        /// A pinned workspace that is not open: dimmed under its stored name (`SidebarItemInfo.closedWorkspace`).
        case closedPin
        /// A pinned tab, page, space or saved group: the app's pass gives it no value, and it draws under the label
        /// stored with it. With no stored label it draws its reference: that is a known gap, not a designed look.
        case storedLabel
        /// The whole sidebar at a launch: clear until its real content (the app's launch reveal).
        case launchCover

        /// The listed state a row in `state` draws; nil for a row that draws its own data.
        public init?(row state: SidebarRowState) {
            switch state {
            case .placeholder: self = .loadingRow
            case .stale: self = .savedRow
            case .live, .creating: return nil
            }
        }
    }

    /// The band's layout, as the model has it.
    public let layout: SidebarLayoutDocument
    /// The items' values (`SidebarModel.itemInfo`).
    public let infos: [LayoutItemID: SidebarItemInfo]
    /// The states of the list's rows; empty checks the band alone.
    public let rows: [SidebarRowState]

    public init(layout: SidebarLayoutDocument, infos: [LayoutItemID: SidebarItemInfo], rows: [SidebarRowState] = []) {
        self.layout = layout
        self.infos = infos
        self.rows = rows
    }

    /// The band of `model`, as it is in this turn.
    @MainActor public init(_ model: SidebarModel) {
        self.init(layout: model.layout, infos: model.itemInfo)
    }

    /// Whether `item` draws from a value the app writes: a built-in, an app or a workspace. Another item (a pinned
    /// tab, page, space or saved group) draws from its stored fields (`DesignedState.storedLabel`).
    public func needsValue(_ item: LayoutItem) -> Bool {
        item.ref.builtIn != nil || item.ref.kind == LayoutItemRef.workspaceKind || item.ref.kind == LayoutItemRef.appKind
    }

    /// The band items that need a value and have none. Such an item is in no designed state.
    public var faults: [LayoutItem] {
        layout.sections.flatMap(\.items).filter { needsValue($0) && infos[$0.id] == nil }
    }

    /// Each band item that needs a value has it.
    public var isComplete: Bool {
        layout.sections.allSatisfy { $0.items.allSatisfy { !needsValue($0) || infos[$0.id] != nil } }
    }

    /// The listed states this frame draws (never `launchCover`, which the app's launch owns).
    public var designedStates: Set<DesignedState> {
        var states = Set(rows.compactMap(DesignedState.init(row:)))
        for item in layout.sections.flatMap(\.items) {
            if !needsValue(item) { states.insert(.storedLabel) }
            if item.ref.kind == LayoutItemRef.workspaceKind, let info = infos[item.id], info.isMissing, !info.isHidden {
                states.insert(.closedPin)
            }
        }
        return states
    }
}
