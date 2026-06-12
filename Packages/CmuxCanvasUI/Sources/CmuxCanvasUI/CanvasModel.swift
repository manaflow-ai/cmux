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
        let idSet = Set(panelIds)
        for paneID in layout.paneIDs where !idSet.contains(paneID.rawValue) {
            layout.remove(paneID)
            changed = true
        }

        var added: [UUID] = []
        let placer = CanvasPlacer(metrics: metrics)
        for panelId in panelIds where !layout.contains(CanvasPaneID(rawValue: panelId)) {
            let anchor = focusedPanelId
                .flatMap { layout.frame(of: CanvasPaneID(rawValue: $0)) }
                ?? layout.panes.last?.frame
            let frame = placer.frameForNewPane(
                size: Self.defaultPaneSize,
                near: anchor,
                avoiding: layout.panes.map(\.frame)
            )
            layout.add(CanvasPane(id: CanvasPaneID(rawValue: panelId), frame: frame))
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
            let paneID = CanvasPaneID(rawValue: panelId)
            guard !layout.contains(paneID), rect.width > 1, rect.height > 1 else { continue }
            layout.add(CanvasPane(id: paneID, frame: CanvasRect(rect)))
            changed = true
        }
        if changed { revision &+= 1 }
    }

    /// The frame of a pane, in canvas coordinates.
    public func frame(of panelId: UUID) -> CGRect? {
        layout.frame(of: CanvasPaneID(rawValue: panelId))?.cgRect
    }

    /// Replaces a pane frame (gesture commit or socket command).
    public func setFrame(_ frame: CGRect, for panelId: UUID) {
        layout.setFrame(CanvasRect(frame), for: CanvasPaneID(rawValue: panelId))
        revision &+= 1
    }

    /// Raises a pane to the front of the z-order.
    public func bringToFront(_ panelId: UUID) {
        layout.bringToFront(CanvasPaneID(rawValue: panelId))
        revision &+= 1
    }

    /// Snaps a frame being moved. Pure passthrough to the snap engine.
    ///
    /// - Parameter snapping: Pass `false` (Command held) to suspend snapping;
    ///   the proposed frame comes back unchanged.
    func snapForMove(proposed: CGRect, movingPanelId: UUID, snapping: Bool) -> CanvasSnapResult {
        CanvasSnapEngine(metrics: gestureMetrics(snapping: snapping)).snapForMove(
            proposed: CanvasRect(proposed),
            neighbors: layout.frames(excluding: CanvasPaneID(rawValue: movingPanelId))
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
        CanvasSnapEngine(metrics: gestureMetrics(snapping: snapping)).snapForResize(
            proposed: CanvasRect(proposed),
            edges: edges,
            neighbors: layout.frames(excluding: CanvasPaneID(rawValue: panelId))
        )
    }

    /// Replaces the whole layout with persisted frames (already in z-order,
    /// back to front). Used by session restore.
    public func restoreFrames(_ ordered: [(id: UUID, frame: CGRect)]) {
        layout = CanvasLayout(panes: ordered.map { entry in
            CanvasPane(id: CanvasPaneID(rawValue: entry.id), frame: CanvasRect(entry.frame))
        })
        revision &+= 1
    }

    /// The layout in persistence order (z-order, back to front).
    public var persistablePanes: [(panelId: UUID, frame: CGRect)] {
        layout.panes.map { ($0.id.rawValue, $0.frame.cgRect) }
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

    /// The neighboring pane in a spatial direction from the given pane.
    public func pane(_ direction: CanvasDirection, from panelId: UUID) -> UUID? {
        CanvasSpatialNavigator()
            .pane(direction, from: CanvasPaneID(rawValue: panelId), in: layout)?
            .rawValue
    }

    /// The smallest rect containing every pane, in canvas coordinates.
    public var contentBounds: CGRect? {
        layout.contentBounds?.cgRect
    }
}
