import Foundation
public import Observation

@Observable @MainActor
public final class ScreenModel: Identifiable {
    public let id: String
    public internal(set) var handle: ScreenID
    /// Durable resource id (`screen_…`) on registry daemons.
    public internal(set) var resourceID: ResourceID?
    public internal(set) var name: String?
    /// The split tree. While the store holds this screen's tree (a pending split's overlay takes its pane out and puts
    /// it back around each daemon batch), writes are held and the lift publishes only the net change, once
    /// (``holdTree()`` / ``publishHeldTree()``), as ``WorkspaceModel/screens`` is held for a pending create.
    public internal(set) var layout: LayoutNode {
        get {
            access(keyPath: \.layout)
            return layoutValue
        }
        set {
            guard treeBeforeHold == nil else {
                layoutValue = newValue
                return
            }
            withMutation(keyPath: \.layout) { layoutValue = newValue }
        }
    }
    @ObservationIgnored private var layoutValue: LayoutNode
    /// Horizontal scrolling columns; empty for an ordinary split screen. Held with ``layout``.
    public internal(set) var columns: [ColumnSnapshot] {
        get {
            access(keyPath: \.columns)
            return columnList
        }
        set {
            guard treeBeforeHold == nil else {
                columnList = newValue
                return
            }
            withMutation(keyPath: \.columns) { columnList = newValue }
        }
    }
    @ObservationIgnored private var columnList: [ColumnSnapshot]
    public internal(set) var viewportBaseWidth: Double
    /// The pane the screen shows alone; nil shows the whole layout. Held with ``layout``: a pending zoom's overlay takes
    /// it out and puts it back around each daemon batch.
    public internal(set) var zoomedPane: PaneID? {
        get {
            access(keyPath: \.zoomedPane)
            return zoomedValue
        }
        set {
            guard treeBeforeHold == nil else {
                zoomedValue = newValue
                return
            }
            withMutation(keyPath: \.zoomedPane) { zoomedValue = newValue }
        }
    }
    @ObservationIgnored private var zoomedValue: PaneID?
    public internal(set) var defaultPane: PaneID?
    /// The daemon's active screen of its workspace, as of the last snapshot or screen record
    /// (no event moves it in between): where a `move-tab-to-workspace` lands.
    public internal(set) var isActive: Bool
    /// Held with ``layout``. Every write, held or not, recounts the unread tally (``adoptUnread()``).
    public internal(set) var panes: [PaneModel] {
        get {
            access(keyPath: \.panes)
            return paneList
        }
        set {
            if treeBeforeHold == nil {
                withMutation(keyPath: \.panes) { paneList = newValue }
            } else {
                paneList = newValue
            }
            adoptUnread()
        }
    }
    @ObservationIgnored private var paneList: [PaneModel]
    /// The tree as it was published when the store began holding it (``holdTree()``); nil while not held.
    @ObservationIgnored private var treeBeforeHold: (layout: LayoutNode, columns: [ColumnSnapshot], panes: [PaneModel], zoomed: PaneID?)?
    /// Palette token, nil = none (`screen-metadata-v1`).
    public internal(set) var color: String?
    /// SF Symbol name or one emoji grapheme.
    public internal(set) var icon: String?
    public internal(set) var pinned: Bool
    /// The screen group this screen belongs to (`screen-groups-v1`).
    public internal(set) var group: ScreenGroupID?
    /// Splits whose divider draws no line (`split-divider-visibility-v1`); they still drag.
    public internal(set) var hiddenDividers: Set<SplitID>

    /// Shows or hides `split`'s divider line here (a Hide / Show Divider intent, until the daemon's layout says it).
    func setDivider(_ split: SplitID, visible: Bool) {
        if visible { hiddenDividers.remove(split) } else { hiddenDividers.insert(split) }
    }
    /// Color, icon, pin, and group come from the daemon's state resources
    /// (`DaemonStore.session`), which the raw tree does not carry.
    @ObservationIgnored var metadataFromState = false

    init(_ s: ScreenSnapshot) {
        id = Self.identity(s)
        handle = s.id
        resourceID = s.resourceID
        name = s.name
        layoutValue = s.layout
        columnList = s.columns
        viewportBaseWidth = s.viewportBaseWidth ?? 1
        zoomedValue = s.zoomedPane
        defaultPane = s.activePane
        isActive = s.active
        paneList = s.panes.map(PaneModel.init)
        color = s.color
        icon = s.icon
        pinned = s.pinned
        group = s.group
        hiddenDividers = s.hiddenDividers
        adoptUnread()
    }

    /// Its panes' unread count (``UnreadTally``), kept by ``recountUnread()``.
    @ObservationIgnored private(set) var unread = UnreadTally()
    /// The workspace that counts this screen.
    @ObservationIgnored weak var unreadWorkspace: WorkspaceModel?

    /// The panes changed: they report to this screen, which recounts.
    private func adoptUnread() {
        for pane in panes where pane.unreadScreen !== self { pane.unreadScreen = self }
        recountUnread()
    }

    /// Counts its panes again and tells its workspace when the count changed.
    func recountUnread() {
        var tally = UnreadTally()
        for pane in panes { tally.add(pane.unread) }
        guard tally != unread else { return }
        unread = tally
        unreadWorkspace?.recountUnread()
    }

    static func identity(_ s: ScreenSnapshot) -> String {
        s.resourceID?.rawValue ?? "screen:\(s.id.rawValue)"
    }

    func update(_ s: ScreenSnapshot) {
        if handle != s.id { handle = s.id }
        if resourceID != s.resourceID { resourceID = s.resourceID }
        if name != s.name { name = s.name }
        if layout != s.layout { layout = s.layout }
        if columns != s.columns { columns = s.columns }
        if viewportBaseWidth != (s.viewportBaseWidth ?? 1) { viewportBaseWidth = s.viewportBaseWidth ?? 1 }
        if zoomedPane != s.zoomedPane { zoomedPane = s.zoomedPane }
        if defaultPane != s.activePane { defaultPane = s.activePane }
        if hiddenDividers != s.hiddenDividers { hiddenDividers = s.hiddenDividers }
        if isActive != s.active { isActive = s.active }
        if !metadataFromState {
            if color != s.color { color = s.color }
            if icon != s.icon { icon = s.icon }
            if pinned != s.pinned { pinned = s.pinned }
            if group != s.group { group = s.group }
        }
        if let reordered = reconcile(panes, with: s.panes, id: PaneModel.identity, make: PaneModel.init, update: { $0.update($1) }) {
            panes = reordered
        }
    }

    /// Lays a `layout-changed` layout (`layout-delta-v1`) over the record:
    /// the layout fields only; panes and metadata keep their own deltas.
    func applyLayout(_ d: ScreenLayoutDelta) {
        if layout != d.layout { layout = d.layout }
        if columns != d.columns { columns = d.columns }
        if viewportBaseWidth != (d.viewportBaseWidth ?? 1) { viewportBaseWidth = d.viewportBaseWidth ?? 1 }
        if zoomedPane != d.zoomedPane { zoomedPane = d.zoomedPane }
        if defaultPane != d.activePane { defaultPane = d.activePane }
        if hiddenDividers != d.hiddenDividers { hiddenDividers = d.hiddenDividers }
    }

    /// Lays the daemon's screen state over the record.
    func applyState(_ state: SessionStateMirror.ScreenState) {
        metadataFromState = true
        if color != state.color { color = state.color }
        if icon != state.icon { icon = state.icon }
        if pinned != state.pinned { pinned = state.pinned }
        let value = state.group.map { ScreenGroupID(rawValue: $0) }
        if group != value { group = value }
    }

    public func pane(_ handle: PaneID) -> PaneModel? { panes.first { $0.handle == handle } }

    /// Holds the publication of ``layout``, ``columns``, ``panes`` and ``zoomedPane`` until ``publishHeldTree()``
    /// (``DaemonStore/withOverlayLifted(writer:snapshot:_:)``): the writes still change the record at once.
    func holdTree() {
        if treeBeforeHold == nil { treeBeforeHold = (layoutValue, columnList, paneList, zoomedValue) }
    }

    /// Publishes each held field once, only when it is not what it was when held (panes by identity).
    func publishHeldTree() {
        guard let before = treeBeforeHold else { return }
        treeBeforeHold = nil
        if before.layout != layoutValue { withMutation(keyPath: \.layout) {} }
        if before.columns != columnList { withMutation(keyPath: \.columns) {} }
        if !before.panes.elementsEqual(paneList, by: ===) { withMutation(keyPath: \.panes) {} }
        if before.zoomed != zoomedValue { withMutation(keyPath: \.zoomedPane) {} }
    }

}
