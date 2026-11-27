public import CoreGraphics

/// One screen shown as a canvas (plans/cmux-next/canvas-layout.md): each
/// pane's frame in canvas points, the stacking order and the camera.
///
/// The panes come from the daemon's screen; ``reconcile(panes:anchor:)``
/// drops the frames of panes that left and places the panes that joined.
/// A pure value: every change is synchronous and deterministic.
///
/// ```swift
/// var canvas = CanvasScreen(seed: shownFrames, viewport: view.bounds.size)
/// canvas.setFrame(CGRect(x: 40, y: 40, width: 640, height: 400), for: pane)
/// ```
public nonisolated struct CanvasScreen: Hashable, Sendable {
    /// Space the canvas keeps between panes it places or packs, in canvas points.
    public static let gap: CGFloat = 16
    /// The size of a pane placed with no pane to copy the size of.
    public static let defaultPaneSize = CGSize(width: 720, height: 450)

    /// Each pane's frame in canvas points (top-left origin).
    public private(set) var frames: [PaneID: CGRect]
    /// Every pane, back to front.
    public private(set) var order: [PaneID]
    /// What the screen shows of the canvas.
    public var camera: CanvasCamera
    /// The camera before Canvas Overview fitted every pane: a second overview
    /// returns to it. Nil when the canvas is not in its overview.
    public var overviewReturn: CanvasCamera?

    /// A canvas with `frames`, stacked in `order` (default: by pane id) and
    /// shown through `camera`.
    public init(frames: [PaneID: CGRect], order: [PaneID]? = nil, camera: CanvasCamera = CanvasCamera()) {
        self.frames = frames
        let known = (order ?? []).filter { frames[$0] != nil }
        self.order = known + frames.keys.filter { !known.contains($0) }.sorted()
        self.camera = camera
    }

    /// A canvas that shows `frames` (view points of a `viewport`-sized view)
    /// where they show now: canvas points are those view points at zoom 1.
    public init(seed frames: [PaneID: CGRect], viewport: CGSize) {
        self.init(frames: frames, camera: CanvasCamera(center: CGPoint(x: viewport.width / 2, y: viewport.height / 2)))
    }

    /// The smallest rect around every pane; nil for an empty canvas.
    public var contentBounds: CGRect? {
        frames.values.reduce(CGRect?.none) { bounds, frame in bounds.map { $0.union(frame) } ?? frame }
    }

    /// The front-most pane whose frame contains `point`.
    public func pane(at point: CGPoint) -> PaneID? {
        order.last(where: { frames[$0]?.contains(point) == true })
    }

    /// Sets the frame of `pane`, if it is on the canvas.
    public mutating func setFrame(_ frame: CGRect, for pane: PaneID) {
        guard frames[pane] != nil else { return }
        frames[pane] = frame
    }

    /// Sets several frames at once; panes not on the canvas are ignored.
    public mutating func setFrames(_ updates: [PaneID: CGRect]) {
        for (pane, frame) in updates where frames[pane] != nil { frames[pane] = frame }
    }

    /// Puts `pane` in front of every other pane.
    public mutating func bringToFront(_ pane: PaneID) {
        guard let index = order.firstIndex(of: pane), index != order.count - 1 else { return }
        order.append(order.remove(at: index))
    }

    /// Makes the canvas hold exactly `panes`: frames of panes not in it drop,
    /// and each pane new to it gets a free frame (`CanvasPlacer`) beside
    /// `anchor` (the focused pane), the anchor's size, in front. Returns
    /// whether anything changed.
    @discardableResult
    public mutating func reconcile(panes: [PaneID], anchor: PaneID?) -> Bool {
        let live = Set(panes)
        let gone = frames.keys.filter { !live.contains($0) }
        let added = panes.filter { frames[$0] == nil }
        guard !gone.isEmpty || !added.isEmpty else { return false }
        for pane in gone { frames[pane] = nil }
        order.removeAll { !live.contains($0) }
        let placer = CanvasPlacer()
        var near = anchor.flatMap { frames[$0] }
        for pane in added {
            let size = near?.size ?? order.last.flatMap { frames[$0]?.size } ?? Self.defaultPaneSize
            let frame = placer.frame(size: size, near: near, avoiding: Array(frames.values))
            frames[pane] = frame
            order.append(pane)
            near = frame
        }
        return true
    }
}
