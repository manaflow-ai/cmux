import Foundation

/// The complete geometric state of one workspace's canvas.
///
/// Holds the ordered pane list; array order is z-order, back to front. The
/// layout is a pure value: every mutation is synchronous, deterministic, and
/// `Codable` round-trips exactly, which is what makes the canvas persistable
/// and unit-testable without any UI.
///
/// Focus is intentionally *not* stored here — the workspace owns focus; the
/// model only answers geometric questions about it (see
/// ``CanvasSpatialNavigator``).
public struct CanvasLayout: Hashable, Codable, Sendable {
    /// Panes in z-order, back to front.
    public private(set) var panes: [CanvasPane]

    /// Creates a layout.
    ///
    /// - Parameter panes: Initial panes in z-order, back to front. Defaults to empty.
    public init(panes: [CanvasPane] = []) {
        self.panes = panes
    }

    /// All pane identifiers in z-order, back to front.
    public var paneIDs: [CanvasPaneID] { panes.map(\.id) }

    /// Whether the layout has no panes.
    public var isEmpty: Bool { panes.isEmpty }

    /// Returns the frame of the given pane, if present.
    ///
    /// - Parameter id: The pane to look up.
    /// - Returns: The pane frame, or `nil` when the pane is not on the canvas.
    public func frame(of id: CanvasPaneID) -> CanvasRect? {
        panes.first(where: { $0.id == id })?.frame
    }

    /// Whether the layout contains the given pane.
    ///
    /// - Parameter id: The pane to test.
    /// - Returns: `true` when present.
    public func contains(_ id: CanvasPaneID) -> Bool {
        panes.contains(where: { $0.id == id })
    }

    /// The frames of every pane except the given one.
    ///
    /// Used as the neighbor set for snapping and placement.
    ///
    /// - Parameter excluded: The pane to leave out.
    /// - Returns: Frames of all other panes, in z-order.
    public func frames(excluding excluded: CanvasPaneID) -> [CanvasRect] {
        panes.compactMap { $0.id == excluded ? nil : $0.frame }
    }

    /// The smallest rect containing every pane, or `nil` for an empty canvas.
    public var contentBounds: CanvasRect? {
        guard let first = panes.first else { return nil }
        return panes.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    /// The top-most pane whose frame contains the given point, if any.
    ///
    /// - Parameter point: A point in canvas coordinates.
    /// - Returns: The front-most hit pane identifier.
    public func topPane(at point: CanvasPoint) -> CanvasPaneID? {
        panes.last(where: { $0.frame.contains(point) })?.id
    }

    /// Adds a pane in front of all existing panes.
    ///
    /// Adding an identifier that is already present replaces its frame and
    /// brings it to the front instead of duplicating it.
    ///
    /// - Parameter pane: The pane to add.
    public mutating func add(_ pane: CanvasPane) {
        panes.removeAll(where: { $0.id == pane.id })
        panes.append(pane)
    }

    /// Removes a pane.
    ///
    /// - Parameter id: The pane to remove. Removing an absent pane is a no-op.
    public mutating func remove(_ id: CanvasPaneID) {
        panes.removeAll(where: { $0.id == id })
    }

    /// Replaces the frame of an existing pane.
    ///
    /// - Parameters:
    ///   - id: The pane to update. Updating an absent pane is a no-op.
    ///   - frame: The new frame in canvas coordinates.
    public mutating func setFrame(_ frame: CanvasRect, for id: CanvasPaneID) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        panes[index].frame = frame
    }

    /// Applies a batch of frame updates in one mutation.
    ///
    /// Identifiers not present in the layout are ignored.
    ///
    /// - Parameter frames: New frames keyed by pane identifier.
    public mutating func setFrames(_ frames: [CanvasPaneID: CanvasRect]) {
        for index in panes.indices {
            if let frame = frames[panes[index].id] {
                panes[index].frame = frame
            }
        }
    }

    /// Moves a pane to the front of the z-order.
    ///
    /// - Parameter id: The pane to raise. Raising an absent pane is a no-op.
    public mutating func bringToFront(_ id: CanvasPaneID) {
        guard let index = panes.firstIndex(where: { $0.id == id }),
              index != panes.indices.last else { return }
        let pane = panes.remove(at: index)
        panes.append(pane)
    }
}
