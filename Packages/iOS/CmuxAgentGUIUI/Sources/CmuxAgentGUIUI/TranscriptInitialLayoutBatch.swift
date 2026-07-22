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

    func measuredCache(
        seededBy seed: [TranscriptRowID: TranscriptRowLayoutCacheEntry]
    ) -> TranscriptInitialLayoutResult? {
        let traits = UITraitCollection(preferredContentSizeCategory: preferredContentSizeCategory)
        var cache: [TranscriptRowID: TranscriptRowLayoutCacheEntry] = [:]
        cache.reserveCapacity(rows.count)
        var computationCount = 0
        for row in rows {
            guard !Task.isCancelled, let spacing = spacingByID[row.rowID] else {
                return nil
            }
            if let cached = seed[row.rowID],
               cached.row == row,
               cached.width == width,
               cached.density == density,
               cached.spacing == spacing,
               cached.askState == .idle {
                cache[row.rowID] = cached
                continue
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
                spacing: spacing,
                height: layout.height,
                askState: .idle,
                layout: layout
            )
            computationCount += 1
        }
        return TranscriptInitialLayoutResult(
            cache: cache,
            computationCount: computationCount
        )
    }
}
#endif
