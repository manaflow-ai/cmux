#if os(iOS)
import CmuxAgentGUIProjection
import UIKit

/// Immutable input and output for a cancellable off-main initial row measurement pass.
struct TranscriptInitialLayoutBatch: Sendable {
    let rows: [TranscriptRow]
    let spacingByID: [TranscriptRowID: TranscriptRowSpacing]
    let width: CGFloat
    let density: TranscriptDensity
    let scale: CGFloat
    let preferredContentSizeCategory: UIContentSizeCategory

    func measuredCache() -> [TranscriptRowID: TranscriptRowLayoutCacheEntry]? {
        let traits = UITraitCollection(preferredContentSizeCategory: preferredContentSizeCategory)
        var cache: [TranscriptRowID: TranscriptRowLayoutCacheEntry] = [:]
        cache.reserveCapacity(rows.count)
        for row in rows {
            guard !Task.isCancelled, let spacing = spacingByID[row.rowID] else {
                return nil
            }
            let layout = TranscriptRowLayout.layout(
                row: row,
                width: width,
                spacing: spacing,
                scale: scale,
                askState: .idle,
                traitCollection: traits
            )
            cache[row.rowID] = TranscriptRowLayoutCacheEntry(
                row: row,
                width: width,
                density: density,
                height: layout.height,
                askState: .idle,
                layout: layout
            )
        }
        return cache
    }
}
#endif
