#if DEBUG
public import Foundation

/// Folds a list of ``SplitCloseRightPaneSnapshot`` plus the empty-panel-appear
/// counter into the capture payload and settle flag the split-close-right
/// scaffold writes after each reconcile attempt.
///
/// This is the pure half of the legacy `collectSplitCloseRightState` local
/// function: given the per-pane facts and the empty-panel-appear count, it
/// derives the same six tally fields, the four shape fields, and the same
/// settle predicate. The app-side driver supplies the snapshots and the counter
/// (the only live reads); everything here is a deterministic value transform, so
/// the byte format of the capture file is reproduced exactly.
///
/// Faithfulness: the produced dictionary keys, their string formatting, and the
/// `settled` boolean expression match the legacy body field-for-field, so the
/// XCUITest reading the capture file observes identical values.
///
/// Isolation: a stateless `Sendable` struct; ``collect(paneSnapshots:bonsplitTabCount:panelCount:emptyPanelAppearCount:)``
/// is a pure function.
public struct SplitCloseRightStateCollector: Sendable {
    /// Creates a collector. The collector holds no state; the instance exists so
    /// the folding lives on a real type rather than as a free function.
    public init() {}

    /// The folded result: the capture payload and whether the layout settled.
    public struct Result: Sendable, Equatable {
        /// The flat string fields to merge into the capture file.
        public var data: [String: String]

        /// `true` when the post-close layout reached its settled 2-pane state.
        public var settled: Bool

        /// Creates a result from its components.
        public init(data: [String: String], settled: Bool) {
            self.data = data
            self.settled = settled
        }
    }

    /// Computes the capture payload and settle flag for one reconcile attempt.
    ///
    /// - Parameters:
    ///   - paneSnapshots: One snapshot per live Bonsplit pane, in pane order.
    ///   - bonsplitTabCount: The total Bonsplit tab count across all panes.
    ///   - panelCount: The workspace's current panel count.
    ///   - emptyPanelAppearCount: The DEBUG empty-panel-appear counter, which
    ///     must be zero for the layout to be considered settled.
    /// - Returns: The capture payload and the settle flag.
    public func collect(
        paneSnapshots: [SplitCloseRightPaneSnapshot],
        bonsplitTabCount: Int,
        panelCount: Int,
        emptyPanelAppearCount: Int
    ) -> Result {
        var missingSelectedTabCount = 0
        var missingPanelMappingCount = 0
        var selectedTerminalCount = 0
        var selectedTerminalAttachedCount = 0
        var selectedTerminalZeroSizeCount = 0
        var selectedTerminalSurfaceNilCount = 0

        for snapshot in paneSnapshots {
            guard snapshot.hasSelectedTab else {
                missingSelectedTabCount += 1
                continue
            }
            guard snapshot.hasPanelMapping else {
                missingPanelMappingCount += 1
                continue
            }
            if snapshot.isTerminal {
                selectedTerminalCount += 1
                if snapshot.isAttached {
                    selectedTerminalAttachedCount += 1
                }
                if snapshot.isZeroSize {
                    selectedTerminalZeroSizeCount += 1
                }
                if snapshot.isSurfaceNil {
                    selectedTerminalSurfaceNilCount += 1
                }
            }
        }

        let settled =
            paneSnapshots.count == 2 &&
            missingSelectedTabCount == 0 &&
            missingPanelMappingCount == 0 &&
            emptyPanelAppearCount == 0 &&
            selectedTerminalCount == 2 &&
            selectedTerminalAttachedCount == 2 &&
            selectedTerminalZeroSizeCount == 0 &&
            selectedTerminalSurfaceNilCount == 0

        return Result(
            data: [
                "finalPaneCount": String(paneSnapshots.count),
                "finalBonsplitTabCount": String(bonsplitTabCount),
                "finalPanelCount": String(panelCount),
                "missingSelectedTabCount": String(missingSelectedTabCount),
                "missingPanelMappingCount": String(missingPanelMappingCount),
                "emptyPanelAppearCount": String(emptyPanelAppearCount),
                "selectedTerminalCount": String(selectedTerminalCount),
                "selectedTerminalAttachedCount": String(selectedTerminalAttachedCount),
                "selectedTerminalZeroSizeCount": String(selectedTerminalZeroSizeCount),
                "selectedTerminalSurfaceNilCount": String(selectedTerminalSurfaceNilCount),
            ],
            settled: settled
        )
    }
}
#endif
