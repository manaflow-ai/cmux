public import Foundation

/// Pure reconcile engine for one Herdr tab, copied from ``RemoteTmuxWindowMirror``.
///
/// AppKit/Bonsplit/Ghostty stay in the host. This type owns the tmux contract:
/// panel lifecycle from the BASE tree, render tree from the VISIBLE one, focus,
/// structure version, and the action list a surface host must apply.
public struct RemoteHerdrWindowMirrorState: Hashable, Sendable {
    /// Herdr tab id.
    public var tabID: String
    /// Display title.
    public var title: String
    /// Base layout.
    public var layout: RemoteHerdrLayoutNode
    /// Visible layout while zoomed.
    public var visibleLayout: RemoteHerdrLayoutNode?
    /// Zoomed flag.
    public var zoomed: Bool
    /// Active pane.
    public var activePaneID: String?
    /// Live pane ids in DFS order (base tree).
    public var paneIDs: [String]
    /// Bumped only when split nesting or pane set changes, never geometry-only.
    public var layoutStructureVersion: Int
    /// Host surface ids keyed by Herdr pane id (filled by the host).
    public var surfaceIDByPaneID: [String: UUID]

    /// Creates mirror state.
    public init(
        tabID: String,
        title: String,
        layout: RemoteHerdrLayoutNode,
        visibleLayout: RemoteHerdrLayoutNode? = nil,
        zoomed: Bool = false,
        activePaneID: String? = nil,
        paneIDs: [String] = [],
        layoutStructureVersion: Int = 0,
        surfaceIDByPaneID: [String: UUID] = [:]
    ) {
        self.tabID = tabID
        self.title = title
        self.layout = layout
        self.visibleLayout = visibleLayout
        self.zoomed = zoomed
        self.activePaneID = activePaneID
        self.paneIDs = paneIDs
        self.layoutStructureVersion = layoutStructureVersion
        self.surfaceIDByPaneID = surfaceIDByPaneID
    }
}

/// Diff produced by one ``RemoteHerdrWindowMirror/apply(window:previous:)`` pass.
public struct RemoteHerdrReconcileResult: Hashable, Sendable {
    /// Panes that need a new TerminalPanel / attach follower.
    public var createdPaneIDs: [String]
    /// Panes whose surfaces must close (gone from the BASE tree).
    public var closedPaneIDs: [String]
    /// Panes that keep their existing surface (including zoom-hidden).
    public var keptPaneIDs: [String]
    /// Whether Bonsplit structure must be rebuilt.
    public var structureChanged: Bool
    /// Title changed.
    public var titleChanged: Bool
    /// Pane that should receive focus, if any.
    public var focusPaneID: String?
    /// Sequential splits for newly created panes.
    public var splitSpecs: [RemoteHerdrSplitSpec]
    /// Render tree to impose on Bonsplit.
    public var renderedLayout: RemoteHerdrLayoutNode

    public init(
        createdPaneIDs: [String] = [],
        closedPaneIDs: [String] = [],
        keptPaneIDs: [String] = [],
        structureChanged: Bool = false,
        titleChanged: Bool = false,
        focusPaneID: String? = nil,
        splitSpecs: [RemoteHerdrSplitSpec] = [],
        renderedLayout: RemoteHerdrLayoutNode
    ) {
        self.createdPaneIDs = createdPaneIDs
        self.closedPaneIDs = closedPaneIDs
        self.keptPaneIDs = keptPaneIDs
        self.structureChanged = structureChanged
        self.titleChanged = titleChanged
        self.focusPaneID = focusPaneID
        self.splitSpecs = splitSpecs
        self.renderedLayout = renderedLayout
    }
}

/// Stateless window-mirror reconcile (tmux ``reconcile(layout:)``).
public enum RemoteHerdrWindowMirror {
    /// Applies a full window update. Zoom never creates or closes panels.
    public static func apply(
        window: RemoteHerdrWindow,
        previous: RemoteHerdrWindowMirrorState?
    ) -> (RemoteHerdrWindowMirrorState, RemoteHerdrReconcileResult) {
        let live = window.basePaneIDs
        let liveSet = Set(live)
        let previousIDs = previous?.paneIDs ?? []
        let previousSet = Set(previousIDs)
        let created = live.filter { !previousSet.contains($0) }
        let createdSet = Set(created)
        let closed = previousIDs.filter { !liveSet.contains($0) }
        let kept = live.filter { previousSet.contains($0) }
        let structureChanged: Bool
        if let previous {
            structureChanged = previous.layout.structureSignature != window.layout.structureSignature
        } else {
            structureChanged = true
        }
        let titleChanged = previous.map { $0.title != window.title } ?? true
        var version = previous?.layoutStructureVersion ?? 0
        if structureChanged, previous != nil {
            version += 1
        }
        let focus = window.activePaneID.flatMap { liveSet.contains($0) ? $0 : nil }
            ?? live.first
        var surfaces = previous?.surfaceIDByPaneID ?? [:]
        for paneID in closed {
            surfaces.removeValue(forKey: paneID)
        }
        let state = RemoteHerdrWindowMirrorState(
            tabID: window.tabID,
            title: window.title,
            layout: window.layout,
            visibleLayout: window.visibleLayout,
            zoomed: window.zoomed,
            activePaneID: focus,
            paneIDs: live,
            layoutStructureVersion: version,
            surfaceIDByPaneID: surfaces
        )
        let result = RemoteHerdrReconcileResult(
            createdPaneIDs: created,
            closedPaneIDs: closed,
            keptPaneIDs: kept,
            structureChanged: structureChanged,
            titleChanged: titleChanged,
            focusPaneID: focus,
            splitSpecs: window.layout.splitSpecs.filter { createdSet.contains($0.paneID) },
            renderedLayout: window.renderedLayout
        )
        return (state, result)
    }

    /// Records a host surface id for a pane (called after TerminalPanel creation).
    public static func bindSurface(
        paneID: String,
        surfaceID: UUID,
        state: inout RemoteHerdrWindowMirrorState
    ) {
        state.surfaceIDByPaneID[paneID] = surfaceID
    }
}
