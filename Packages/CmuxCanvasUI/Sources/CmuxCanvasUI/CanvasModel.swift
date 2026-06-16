public import Foundation
public import CoreGraphics
public import CmuxCanvas

/// The durable canvas state for one workspace.
///
/// Owned by the host (cmux's `Workspace`) so the layout survives view
/// remounts and workspace switches; the canvas view reads and mutates it
/// through this model only. All geometry math is delegated to the pure
/// `CmuxCanvas` package.
@MainActor
public final class CanvasModel {
    /// Reads the current user-configured metrics. Injected by the host so the
    /// package owns no settings storage and tests can pin values.
    private let metricsProvider: () -> CanvasMetrics

    /// The canvas layout (frames + z-order), keyed by panel UUID.
    public private(set) var layout = CanvasLayout()

    /// Monotonic revision so callers can cheaply detect changes.
    public private(set) var revision: UInt64 = 0

    /// The attached canvas view, when one is mounted. Lets the host's action
    /// executors drive viewport operations (reveal, overview) through a
    /// narrow seam.
    public weak var viewport: (any CanvasViewportControlling)?

    /// Last on-screen viewport, in canvas coordinates, persisted across view
    /// remounts so switching workspaces away and back restores exactly where
    /// the user was (center + zoom) instead of snapping to a default.
    public var savedViewport: (canvasCenter: CGPoint, magnification: CGFloat)?

    /// The default size for a brand-new pane that has no seed frame.
    public static let defaultPaneSize = CanvasSize(width: 640, height: 420)

    public init(metricsProvider: @escaping () -> CanvasMetrics) {
        self.metricsProvider = metricsProvider
    }

    /// The metrics every canvas operation should use right now.
    var metrics: CanvasMetrics { metricsProvider() }

    /// Reconciles the canvas with the host's current panel set.
    ///
    /// New panels are placed near the focused pane at the canonical gap;
    /// panels that no longer exist leave the canvas. Returns the IDs of
    /// panes that were newly added, so the caller can reveal them.
    @discardableResult
    public func syncPanes(panelIds: [UUID], focusedPanelId: UUID?) -> [UUID] {
        var changed = false
        let idSet = Set(panelIds.map(CanvasPanelID.init(rawValue:)))
        for panelId in layout.allPanelIds where !idSet.contains(panelId) {
            layout.removePanel(panelId)
            changed = true
        }

        var added: [UUID] = []
        let placer = CanvasPlacer(metrics: metrics)
        var occupiedFrames = layout.panes.map(\.frame)
        for panelId in panelIds where layout.pane(containing: CanvasPanelID(rawValue: panelId)) == nil {
            let anchor = focusedPanelId
                .flatMap { layout.pane(containing: CanvasPanelID(rawValue: $0)) }
                .flatMap { layout.frame(of: $0) }
                ?? layout.panes.last?.frame
            let frame = placer.frameForNewPane(
                size: Self.defaultPaneSize,
                near: anchor,
                avoiding: occupiedFrames
            )
            let pane = CanvasPane(id: CanvasPaneID(rawValue: panelId), frame: frame)
            layout.add(pane)
            occupiedFrames.append(pane.frame)
            added.append(panelId)
            changed = true
        }
        if changed { revision &+= 1 }
        return added
    }

    /// Seeds pane frames from the host's split layout so entering canvas
    /// mode preserves what the user sees. Only panes without a canvas frame
    /// are seeded; an existing canvas arrangement is never overwritten.
    public func seedFromSplitFrames(_ frames: [UUID: CGRect]) {
        var changed = false
        for (panelId, rect) in frames {
            guard layout.pane(containing: CanvasPanelID(rawValue: panelId)) == nil,
                  rect.width > 1, rect.height > 1 else { continue }
            layout.add(CanvasPane(id: CanvasPaneID(rawValue: panelId), frame: CanvasRect(rect)))
            changed = true
        }
        if changed { revision &+= 1 }
    }

    /// The pane hosting the given panel.
    public func paneID(containing panelId: UUID) -> CanvasPaneID? {
        layout.pane(containing: CanvasPanelID(rawValue: panelId))
    }

    /// The frame of the pane hosting the given panel, in canvas coordinates.
    public func frame(of panelId: UUID) -> CGRect? {
        paneID(containing: panelId).flatMap { layout.frame(of: $0)?.cgRect }
    }

    /// Replaces the frame of the pane hosting the panel (gesture commit or
    /// socket command). Moving a tab's pane moves all its tabs.
    public func setFrame(_ frame: CGRect, for panelId: UUID) {
        guard let paneID = paneID(containing: panelId) else { return }
        layout.setFrame(CanvasRect(frame), for: paneID)
        revision &+= 1
    }

    /// Raises the pane hosting the panel to the front of the z-order.
    public func bringToFront(_ panelId: UUID) {
        guard let paneID = paneID(containing: panelId) else { return }
        layout.bringToFront(paneID)
        revision &+= 1
    }

    // MARK: - Tabs

    /// Selects the panel as its pane's visible tab.
    public func selectPanel(_ panelId: UUID) {
        layout.selectPanel(CanvasPanelID(rawValue: panelId))
        revision &+= 1
    }

    /// Moves `panelId` into the pane hosting `targetPanelId` (a join). The
    /// source pane disappears when it loses its last tab.
    /// - Returns: Whether the join happened.
    @discardableResult
    public func joinPanel(_ panelId: UUID, withPaneContaining targetPanelId: UUID) -> Bool {
        let source = CanvasPanelID(rawValue: panelId)
        guard let destination = layout.pane(containing: CanvasPanelID(rawValue: targetPanelId)),
              layout.pane(containing: source) != nil,
              layout.pane(containing: source) != destination else { return false }
        layout.addPanel(source, toPane: destination, select: true)
        revision &+= 1
        return true
    }

    /// Breaks the panel out of its multi-tab pane into a new pane placed
    /// near the source at the canonical gap.
    /// - Returns: Whether the break happened.
    @discardableResult
    public func breakOutPanel(_ panelId: UUID) -> Bool {
        let panel = CanvasPanelID(rawValue: panelId)
        guard let sourcePaneID = layout.pane(containing: panel),
              layout.panelIds(in: sourcePaneID)?.count ?? 0 > 1,
              let sourceFrame = layout.frame(of: sourcePaneID) else { return false }
        let frame = CanvasPlacer(metrics: metrics).frameForNewPane(
            size: sourceFrame.size,
            near: sourceFrame,
            avoiding: layout.panes.map(\.frame)
        )
        // Mint a fresh pane identity rather than reusing the panel UUID. A
        // single-tab pane's id equals its founding panel's UUID, so reusing
        // `panelId` would collide with the source pane when the torn-out tab
        // is that founding panel — `layout.breakOutPanel`'s `!contains` guard
        // would reject it, and the first/founding tab could never tear out.
        let didBreak = layout.breakOutPanel(
            panel,
            intoPane: CanvasPaneID(rawValue: UUID()),
            frame: frame
        )
        if didBreak { revision &+= 1 }
        return didBreak
    }

    /// Snaps a frame being moved. Pure passthrough to the snap engine.
    ///
    /// - Parameter snapping: Pass `false` (Command held) to suspend snapping;
    ///   the proposed frame comes back unchanged.
    func snapForMove(proposed: CGRect, movingPanelId: UUID, snapping: Bool) -> CanvasSnapResult {
        let movingPane = paneID(containing: movingPanelId) ?? CanvasPaneID(rawValue: movingPanelId)
        return CanvasSnapEngine(metrics: gestureMetrics(snapping: snapping)).snapForMove(
            proposed: CanvasRect(proposed),
            neighbors: layout.frames(excluding: movingPane)
        )
    }

    /// Snaps and min-size-clamps a frame being resized.
    ///
    /// - Parameter snapping: Pass `false` (Command held) to suspend snapping;
    ///   only the minimum-size clamp applies.
    func snapForResize(
        proposed: CGRect,
        edges: CanvasResizeEdges,
        panelId: UUID,
        snapping: Bool
    ) -> CanvasSnapResult {
        let resizingPane = paneID(containing: panelId) ?? CanvasPaneID(rawValue: panelId)
        return CanvasSnapEngine(metrics: gestureMetrics(snapping: snapping)).snapForResize(
            proposed: CanvasRect(proposed),
            edges: edges,
            neighbors: layout.frames(excluding: resizingPane)
        )
    }

    /// One persisted pane: identity, frame, ordered tabs, selection.
    public struct PersistablePane {
        public let paneId: UUID
        public let frame: CGRect
        public let panelIds: [UUID]
        public let selectedPanelId: UUID

        public init(paneId: UUID, frame: CGRect, panelIds: [UUID], selectedPanelId: UUID) {
            self.paneId = paneId
            self.frame = frame
            self.panelIds = panelIds
            self.selectedPanelId = selectedPanelId
        }
    }

    /// Replaces the whole layout with persisted panes (already in z-order,
    /// back to front). Used by session restore; panes restored with an empty
    /// panel list are dropped.
    public func restorePanes(_ ordered: [PersistablePane]) {
        layout = CanvasLayout(panes: ordered.compactMap { entry in
            let panelIds = entry.panelIds.map(CanvasPanelID.init(rawValue:))
            guard !panelIds.isEmpty else { return nil }
            return CanvasPane(
                id: CanvasPaneID(rawValue: entry.paneId),
                frame: CanvasRect(entry.frame),
                panelIds: panelIds,
                selectedPanelId: CanvasPanelID(rawValue: entry.selectedPanelId)
            )
        })
        revision &+= 1
    }

    /// Replaces the whole layout with persisted single-tab frames. Used by
    /// session restore of pre-tab snapshots and by tests.
    public func restoreFrames(_ ordered: [(id: UUID, frame: CGRect)]) {
        restorePanes(ordered.map { entry in
            PersistablePane(
                paneId: entry.id,
                frame: entry.frame,
                panelIds: [entry.id],
                selectedPanelId: entry.id
            )
        })
    }

    /// The layout in persistence order (z-order, back to front).
    public var persistablePanes: [PersistablePane] {
        layout.panes.map { pane in
            PersistablePane(
                paneId: pane.id.rawValue,
                frame: pane.frame.cgRect,
                panelIds: pane.panelIds.map(\.rawValue),
                selectedPanelId: pane.selectedPanelId.rawValue
            )
        }
    }

    private func gestureMetrics(snapping: Bool) -> CanvasMetrics {
        var metrics = metrics
        if !snapping {
            metrics.snapThreshold = 0
        }
        return metrics
    }

    /// Applies an alignment command to the given panes (or all panes when
    /// fewer than two are passed) and returns whether anything changed.
    @discardableResult
    public func applyAlignment(
        _ command: CanvasAlignmentCommand,
        to panelIds: [UUID],
        reference: UUID?
    ) -> Bool {
        let targets = panelIds.count >= 2 ? panelIds.map(CanvasPaneID.init(rawValue:)) : layout.paneIDs
        let frames = CanvasAligner(metrics: metrics).frames(
            applying: command,
            to: targets,
            in: layout,
            reference: reference.map(CanvasPaneID.init(rawValue:))
        )
        guard !frames.isEmpty else { return false }
        layout.setFrames(frames)
        revision &+= 1
        return true
    }

    /// The selected panel of the neighboring pane in a spatial direction
    /// from the pane hosting the given panel.
    public func pane(_ direction: CanvasDirection, from panelId: UUID) -> UUID? {
        guard let sourcePane = paneID(containing: panelId),
              let neighbor = CanvasSpatialNavigator().pane(direction, from: sourcePane, in: layout) else {
            return nil
        }
        return layout.selectedPanelId(in: neighbor)?.rawValue
    }

    /// The smallest rect containing every pane, in canvas coordinates.
    public var contentBounds: CGRect? {
        layout.contentBounds?.cgRect
    }
}
