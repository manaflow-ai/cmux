import Foundation

/// Executes ``CanvasAlignmentCommand``s, producing the frame updates to apply.
///
/// The aligner never mutates a layout itself; it returns new frames keyed by
/// pane so the caller can apply them through ``CanvasLayout/setFrames(_:)``
/// (and animate or persist them as it sees fit).
public struct CanvasAligner: Sendable {
    /// The metrics supplying the canonical gap.
    public let metrics: CanvasMetrics

    /// Creates an aligner.
    ///
    /// - Parameter metrics: The metrics supplying the canonical gap.
    public init(metrics: CanvasMetrics) {
        self.metrics = metrics
    }

    /// Computes the frames produced by applying a command to a set of panes.
    ///
    /// - Parameters:
    ///   - command: The alignment or distribution to perform.
    ///   - ids: The panes to operate on. Identifiers absent from the layout
    ///     are ignored; fewer than two resolved panes yields no changes.
    ///   - layout: The current canvas layout.
    ///   - reference: The pane whose width/height the equalize commands copy,
    ///     typically the focused pane. When `nil` or not part of `ids`, the
    ///     widest (respectively tallest) pane is used.
    /// - Returns: New frames keyed by pane identifier; empty when the command
    ///   changes nothing.
    public func frames(
        applying command: CanvasAlignmentCommand,
        to ids: [CanvasPaneID],
        in layout: CanvasLayout,
        reference: CanvasPaneID? = nil
    ) -> [CanvasPaneID: CanvasRect] {
        let selection = resolvedSelection(ids, in: layout)
        guard selection.count >= 2 else { return [:] }

        switch command {
        case .alignLeft:
            let target = selection.map(\.frame.minX).min() ?? 0
            return changedFrames(selection) { frame in
                CanvasRect(x: target, y: frame.y, width: frame.width, height: frame.height)
            }
        case .alignRight:
            let target = selection.map(\.frame.maxX).max() ?? 0
            return changedFrames(selection) { frame in
                CanvasRect(x: target - frame.width, y: frame.y, width: frame.width, height: frame.height)
            }
        case .alignTop:
            let target = selection.map(\.frame.minY).min() ?? 0
            return changedFrames(selection) { frame in
                CanvasRect(x: frame.x, y: target, width: frame.width, height: frame.height)
            }
        case .alignBottom:
            let target = selection.map(\.frame.maxY).max() ?? 0
            return changedFrames(selection) { frame in
                CanvasRect(x: frame.x, y: target - frame.height, width: frame.width, height: frame.height)
            }
        case .equalizeWidths:
            let target = referencePane(reference, in: selection, widest: true).frame.width
            return changedFrames(selection) { frame in
                CanvasRect(x: frame.x, y: frame.y, width: target, height: frame.height)
            }
        case .equalizeHeights:
            let target = referencePane(reference, in: selection, widest: false).frame.height
            return changedFrames(selection) { frame in
                CanvasRect(x: frame.x, y: frame.y, width: frame.width, height: target)
            }
        case .distributeHorizontally:
            return distributedFrames(selection, horizontally: true)
        case .distributeVertically:
            return distributedFrames(selection, horizontally: false)
        case .tidy:
            return tidiedFrames(selection)
        }
    }

    private func resolvedSelection(_ ids: [CanvasPaneID], in layout: CanvasLayout) -> [CanvasPane] {
        var seen = Set<CanvasPaneID>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let frame = layout.frame(of: id) else { return nil }
            return CanvasPane(id: id, frame: frame)
        }
    }

    private func changedFrames(
        _ selection: [CanvasPane],
        transform: (CanvasRect) -> CanvasRect
    ) -> [CanvasPaneID: CanvasRect] {
        var result: [CanvasPaneID: CanvasRect] = [:]
        for pane in selection {
            let updated = transform(pane.frame)
            if updated != pane.frame {
                result[pane.id] = updated
            }
        }
        return result
    }

    private func referencePane(
        _ reference: CanvasPaneID?,
        in selection: [CanvasPane],
        widest: Bool
    ) -> CanvasPane {
        if let reference, let pane = selection.first(where: { $0.id == reference }) {
            return pane
        }
        // Deterministic fallback: largest along the equalized dimension, then by id.
        return selection.max(by: { lhs, rhs in
            let l = widest ? lhs.frame.width : lhs.frame.height
            let r = widest ? rhs.frame.width : rhs.frame.height
            if l != r { return l < r }
            return rhs.id < lhs.id
        })!
    }

    private func distributedFrames(
        _ selection: [CanvasPane],
        horizontally: Bool
    ) -> [CanvasPaneID: CanvasRect] {
        let sorted = selection.sorted(by: { lhs, rhs in
            let l = horizontally ? lhs.frame.minX : lhs.frame.minY
            let r = horizontally ? rhs.frame.minX : rhs.frame.minY
            if l != r { return l < r }
            return lhs.id < rhs.id
        })
        var result: [CanvasPaneID: CanvasRect] = [:]
        guard let first = sorted.first else { return result }
        var cursor = horizontally ? first.frame.maxX : first.frame.maxY
        for pane in sorted.dropFirst() {
            var frame = pane.frame
            if horizontally {
                frame.x = cursor + metrics.gap
                cursor = frame.maxX
            } else {
                frame.y = cursor + metrics.gap
                cursor = frame.maxY
            }
            if frame != pane.frame {
                result[pane.id] = frame
            }
        }
        return result
    }

    private func tidiedFrames(_ selection: [CanvasPane]) -> [CanvasPaneID: CanvasRect] {
        let originX = selection.map(\.frame.minX).min() ?? 0
        let originY = selection.map(\.frame.minY).min() ?? 0

        // Band panes into rows by vertical center: a pane joins the current row
        // while its center lies above the row's running bottom edge.
        let sorted = selection.sorted(by: { lhs, rhs in
            if lhs.frame.midY != rhs.frame.midY { return lhs.frame.midY < rhs.frame.midY }
            if lhs.frame.midX != rhs.frame.midX { return lhs.frame.midX < rhs.frame.midX }
            return lhs.id < rhs.id
        })
        var rows: [[CanvasPane]] = []
        var rowBottom = -Double.infinity
        for pane in sorted {
            if rows.isEmpty || pane.frame.midY >= rowBottom {
                rows.append([pane])
                rowBottom = pane.frame.maxY
            } else {
                rows[rows.count - 1].append(pane)
                rowBottom = max(rowBottom, pane.frame.maxY)
            }
        }

        var result: [CanvasPaneID: CanvasRect] = [:]
        var y = originY
        for row in rows {
            let ordered = row.sorted(by: { lhs, rhs in
                if lhs.frame.midX != rhs.frame.midX { return lhs.frame.midX < rhs.frame.midX }
                return lhs.id < rhs.id
            })
            var x = originX
            var rowHeight: Double = 0
            for pane in ordered {
                let frame = CanvasRect(x: x, y: y, width: pane.frame.width, height: pane.frame.height)
                if frame != pane.frame {
                    result[pane.id] = frame
                }
                x = frame.maxX + metrics.gap
                rowHeight = max(rowHeight, pane.frame.height)
            }
            y += rowHeight + metrics.gap
        }
        return result
    }
}
