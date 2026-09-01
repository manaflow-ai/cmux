import CMUXMobileCore
import Foundation

/// Lifecycle state for one mounted terminal mirror.
///
/// The state is the single source of truth for whether a surface needs
/// scrollback hydration and whether its rendered mirror may be reused after a
/// connection swap. Producer identity and history metadata make the reuse
/// decision fail closed when the Mac recreated the surface or history moved.
struct MobileTerminalMirrorState: Sendable {
    var hydrationNeeded = true
    var retainedAcrossReconnect = false
    private(set) var renderEpoch: String?
    private(set) var historyRows: UInt64?
    private(set) var rowSpaceRevision: UInt64?

    /// Marks the mirror as blank and requiring a full screen-anchored replay.
    mutating func invalidate() {
        hydrationNeeded = true
        retainedAcrossReconnect = false
        renderEpoch = nil
        historyRows = nil
        rowSpaceRevision = nil
    }

    /// Carries a populated mounted mirror across a connection swap only when
    /// its last delivered frame proved that hydration had completed.
    mutating func prepareForReconnect(hasDeliveredFrame: Bool) {
        retainedAcrossReconnect = hasDeliveredFrame && !hydrationNeeded
        hydrationNeeded = !retainedAcrossReconnect
    }

    /// Records producer metadata from a delivered frame. A full frame with no
    /// retained history still completes hydration; deltas never do.
    mutating func record(_ frame: MobileTerminalRenderGridFrame) {
        if retainedAcrossReconnect && !frame.full {
            return
        }
        renderEpoch = frame.renderEpoch.isEmpty ? nil : frame.renderEpoch
        historyRows = frame.historyRows
        rowSpaceRevision = frame.rowSpaceRevision
        let hydrationSatisfied = retainedAcrossReconnect
            || frame.anchor != .screen
            || frame.scrollbackRows > 0
            || frame.historyRows == 0
            || frame.activeScreen == .alternate
        if frame.full, hydrationSatisfied {
            hydrationNeeded = false
            retainedAcrossReconnect = false
        }
    }

    /// Returns whether a provisional zero-row replay is unsafe for this mirror.
    /// A changed producer epoch, history count, or row-space revision means the
    /// local scrollback can no longer be trusted and must be rehydrated.
    func requiresHydration(for frame: MobileTerminalRenderGridFrame) -> Bool {
        guard retainedAcrossReconnect else { return hydrationNeeded }
        guard let renderEpoch,
              let historyRows,
              let rowSpaceRevision,
              !frame.renderEpoch.isEmpty,
              let frameHistoryRows = frame.historyRows,
              let frameRowSpaceRevision = frame.rowSpaceRevision else {
            return true
        }
        return renderEpoch != frame.renderEpoch
            || historyRows != frameHistoryRows
            || rowSpaceRevision != frameRowSpaceRevision
    }
}
