public import Foundation

/// Picks the hidden browser panes to discard so the memory held by hidden web
/// content fits a budget, starting with the pane hidden longest, like a
/// Chrome tab discard (https://github.com/manaflow-ai/cmux/issues/15069).
///
/// Panes can share a WebContent process, which frees its memory only once no
/// pane uses it, so the process is the unit of eviction. A process that also
/// backs a visible pane is not hidden memory and is never counted.
public struct BrowserHiddenWebViewMemoryBudgetPlanner: Sendable {
    public struct Pane: Equatable, Sendable {
        public let id: UUID
        /// The pane's live WebContent process, or nil when it has none.
        public let processID: Int?
        public let isVisible: Bool
        public let hiddenAt: Date?
        /// Whether the pane may be discarded now.
        public let isEvictable: Bool

        public init(id: UUID, processID: Int?, isVisible: Bool, hiddenAt: Date?, isEvictable: Bool) {
            self.id = id
            self.processID = processID
            self.isVisible = isVisible
            self.hiddenAt = hiddenAt
            self.isEvictable = isEvictable
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Physical memory held by processes that back only hidden panes.
        public let hiddenFootprintBytes: UInt64
        /// The same after the planned discards.
        public let remainingHiddenFootprintBytes: UInt64
        /// Panes to discard, hidden longest first.
        public let panesToDiscard: [UUID]
    }

    public let budgetBytes: UInt64

    public init(budgetBytes: UInt64) {
        self.budgetBytes = budgetBytes
    }

    public init(budgetMB: Int) {
        let megabytes = max(0, budgetMB)
        let budgetBytes = megabytes > Int.max / 1_048_576
            ? UInt64.max
            : UInt64(megabytes) * 1_048_576
        self.init(budgetBytes: budgetBytes)
    }

    /// - Parameter footprintBytes: The physical footprint of a process, or
    ///   nil when it cannot be measured. Called only for hidden processes.
    public func plan(panes: [Pane], footprintBytes: (Int) -> UInt64?) -> Plan {
        let visibleProcessIDs = Set(panes.filter(\.isVisible).compactMap(\.processID))
        var hiddenPanesByProcess: [Int: [Pane]] = [:]
        for pane in panes where !pane.isVisible {
            guard let processID = pane.processID, !visibleProcessIDs.contains(processID) else { continue }
            hiddenPanesByProcess[processID, default: []].append(pane)
        }
        var footprints: [Int: UInt64] = [:]
        for processID in hiddenPanesByProcess.keys {
            footprints[processID] = footprintBytes(processID)
        }
        let hiddenFootprintBytes = footprints.values.reduce(0, +)

        // A process is as old as its most recently hidden pane.
        let evictableProcesses = hiddenPanesByProcess
            .filter { processID, panes in
                (footprints[processID] ?? 0) > 0 && panes.allSatisfy(\.isEvictable)
            }
            .map { processID, panes in
                (
                    processID: processID,
                    hiddenAt: panes.map { $0.hiddenAt ?? .distantFuture }.max() ?? .distantFuture,
                    paneIDs: panes.map(\.id)
                )
            }
            .sorted { ($0.hiddenAt, $0.processID) < ($1.hiddenAt, $1.processID) }

        var remainingBytes = hiddenFootprintBytes
        var panesToDiscard: [UUID] = []
        for process in evictableProcesses {
            guard remainingBytes > budgetBytes else { break }
            panesToDiscard += process.paneIDs
            remainingBytes -= footprints[process.processID] ?? 0
        }
        return Plan(
            hiddenFootprintBytes: hiddenFootprintBytes,
            remainingHiddenFootprintBytes: remainingBytes,
            panesToDiscard: panesToDiscard
        )
    }
}
