#if os(iOS)
import CmuxAgentGUIProjection
import UIKit

/// Serializes transcript projection measurement and snapshot application.
public actor TranscriptTransactionQueue {
    private var latestGeneration = 0

    /// Creates a serial transcript transaction queue.
    public init() {}

    func enqueue(
        generation: Int,
        rows: [TranscriptRow],
        diff: TranscriptProjectionDiff,
        width: CGFloat,
        environment: TranscriptMeasurementEnvironment,
        cache: TranscriptMeasurementCache,
        apply: @escaping @MainActor @Sendable ([TranscriptMeasuredRow], TranscriptProjectionDiff) -> Void
    ) async {
        guard generation >= latestGeneration else {
            return
        }
        latestGeneration = generation
        var measured: [TranscriptMeasuredRow] = []
        measured.reserveCapacity(rows.count)
        for row in rows {
            let height = await cache.height(
                for: row,
                width: width,
                environment: environment
            )
            measured.append(TranscriptMeasuredRow(row: row, height: height))
        }
        guard generation == latestGeneration else {
            return
        }
        await apply(measured, diff)
    }
}
#endif
