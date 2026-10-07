public import CoreGraphics

/// The keep-alive band of a screen (architecture.md 4): the viewport widened
/// by one viewport width on each side. Panes in it keep their content alive,
/// paused, so a column scroll brings them in with no blank frames.
public nonisolated enum KeepAliveBand {
    /// Panes whose `displayed` frame (viewport coordinates) overlaps the band
    /// around `viewport`. Includes the visible panes.
    public static func panes(displayed: [PaneID: CGRect], viewport: CGRect) -> Set<PaneID> {
        guard viewport.width > 0, viewport.height > 0 else { return [] }
        let band = viewport.insetBy(dx: -viewport.width, dy: 0)
        var result: Set<PaneID> = []
        for (pane, frame) in displayed {
            let overlap = frame.intersection(band)
            if !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 { result.insert(pane) }
        }
        return result
    }
}
