public import CoreGraphics

/// Computes the frames a ``CanvasArrangement`` gives the panes of a canvas
/// (classic `CanvasAligner`). It changes nothing itself: it returns the
/// frames that change, which the caller applies with
/// ``CanvasScreen/setFrames(_:)``.
///
/// ```swift
/// let moved = CanvasArranger().frames(.tidy, in: canvas, reference: focused)
/// canvas.setFrames(moved)
/// ```
public nonisolated struct CanvasArranger: Hashable, Sendable {
    /// Space between panes the distribute and tidy commands pack, in canvas points.
    public var gap: CGFloat

    /// An arranger that packs at `gap` canvas points.
    public init(gap: CGFloat = CanvasScreen.gap) {
        self.gap = gap
    }

    /// The frames `command` gives the panes of `canvas` that it moves.
    /// `reference` is the pane whose width or height the equalize commands
    /// copy (the focused pane); without one, the widest or tallest pane. Empty
    /// for fewer than two panes, or when nothing moves.
    public func frames(_ command: CanvasArrangement, in canvas: CanvasScreen, reference: PaneID? = nil) -> [PaneID: CGRect] {
        let panes = canvas.frames.map { (id: $0.key, frame: $0.value) }.sorted { $0.id < $1.id }
        guard panes.count >= 2 else { return [:] }
        func changed(_ transform: (CGRect) -> CGRect) -> [PaneID: CGRect] {
            var result: [PaneID: CGRect] = [:]
            for pane in panes {
                let next = transform(pane.frame)
                if next != pane.frame { result[pane.id] = next }
            }
            return result
        }
        switch command {
        case .alignLeft:
            let x = panes.map { $0.frame.minX }.min() ?? 0
            return changed { CGRect(x: x, y: $0.minY, width: $0.width, height: $0.height) }
        case .alignRight:
            let x = panes.map { $0.frame.maxX }.max() ?? 0
            return changed { CGRect(x: x - $0.width, y: $0.minY, width: $0.width, height: $0.height) }
        case .alignTop:
            let y = panes.map { $0.frame.minY }.min() ?? 0
            return changed { CGRect(x: $0.minX, y: y, width: $0.width, height: $0.height) }
        case .alignBottom:
            let y = panes.map { $0.frame.maxY }.max() ?? 0
            return changed { CGRect(x: $0.minX, y: y - $0.height, width: $0.width, height: $0.height) }
        case .equalizeWidths:
            let width = reference.flatMap { canvas.frames[$0] }?.width ?? panes.map { $0.frame.width }.max() ?? 0
            return changed { CGRect(x: $0.minX, y: $0.minY, width: width, height: $0.height) }
        case .equalizeHeights:
            let height = reference.flatMap { canvas.frames[$0] }?.height ?? panes.map { $0.frame.height }.max() ?? 0
            return changed { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: height) }
        case .distributeHorizontally:
            return distributed(panes, horizontally: true)
        case .distributeVertically:
            return distributed(panes, horizontally: false)
        case .tidy:
            return tidied(panes)
        }
    }

    private func distributed(_ panes: [(id: PaneID, frame: CGRect)], horizontally: Bool) -> [PaneID: CGRect] {
        let sorted = panes.sorted {
            let l = horizontally ? $0.frame.minX : $0.frame.minY, r = horizontally ? $1.frame.minX : $1.frame.minY
            return l != r ? l < r : $0.id < $1.id
        }
        guard let first = sorted.first else { return [:] }
        var cursor = horizontally ? first.frame.maxX : first.frame.maxY
        var result: [PaneID: CGRect] = [:]
        for pane in sorted.dropFirst() {
            var frame = pane.frame
            if horizontally {
                frame.origin.x = cursor + gap
                cursor = frame.maxX
            } else {
                frame.origin.y = cursor + gap
                cursor = frame.maxY
            }
            if frame != pane.frame { result[pane.id] = frame }
        }
        return result
    }

    private func tidied(_ panes: [(id: PaneID, frame: CGRect)]) -> [PaneID: CGRect] {
        let originX = panes.map { $0.frame.minX }.min() ?? 0
        let originY = panes.map { $0.frame.minY }.min() ?? 0
        // A pane joins the current row while its center is above the row's bottom edge.
        let sorted = panes.sorted { ($0.frame.midY, $0.frame.midX, $0.id) < ($1.frame.midY, $1.frame.midX, $1.id) }
        var rows: [[(id: PaneID, frame: CGRect)]] = []
        var rowBottom = -CGFloat.infinity
        for pane in sorted {
            if rows.isEmpty || pane.frame.midY >= rowBottom {
                rows.append([pane])
                rowBottom = pane.frame.maxY
            } else {
                rows[rows.count - 1].append(pane)
                rowBottom = max(rowBottom, pane.frame.maxY)
            }
        }
        var result: [PaneID: CGRect] = [:]
        var y = originY
        for row in rows {
            var x = originX, height: CGFloat = 0
            for pane in row.sorted(by: { ($0.frame.midX, $0.id) < ($1.frame.midX, $1.id) }) {
                let frame = CGRect(x: x, y: y, width: pane.frame.width, height: pane.frame.height)
                if frame != pane.frame { result[pane.id] = frame }
                x = frame.maxX + gap
                height = max(height, frame.height)
            }
            y += height + gap
        }
        return result
    }
}
