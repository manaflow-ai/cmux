public import CMUXMobileCore

/// Lifecycle state for one mounted terminal mirror.
///
/// The state is the single source of truth for whether a surface needs
/// scrollback hydration and whether its rendered mirror may be reused after a
/// connection swap. Producer identity and history metadata make the reuse
/// decision fail closed when the Mac recreated the surface or history moved.
public struct MobileTerminalMirrorState: Sendable {
    /// Whether the next authoritative replay must include scrollback rows.
    public private(set) var hydrationNeeded = true
    /// Whether the mounted mirror is currently eligible for a zero-row replay.
    ///
    /// The shell owns the replay barrier and needs to observe this lifecycle
    /// state, while all mutations remain inside this value type.
    public private(set) var retainedAcrossReconnect = false
    private(set) var renderEpoch: String?
    private(set) var historyRows: UInt64?
    private(set) var rowSpaceRevision: UInt64?

    /// Creates a new mirror state that requires a cold hydration replay.
    public init() {}

    /// Marks the mirror as blank and requiring a full screen-anchored replay.
    public mutating func invalidate() {
        hydrationNeeded = true
        retainedAcrossReconnect = false
        renderEpoch = nil
        historyRows = nil
        rowSpaceRevision = nil
    }

    /// Carries a populated mounted mirror across a connection swap when the
    /// last delivered frame proved that hydration had completed.
    /// - Parameter hasDeliveredFrame: Whether the mounted surface has delivered
    ///   an authoritative frame that can remain visible during reconnect.
    public mutating func prepareForReconnect(hasDeliveredFrame: Bool) {
        retainedAcrossReconnect = hasDeliveredFrame && !hydrationNeeded
        hydrationNeeded = !retainedAcrossReconnect
    }

    /// Records producer metadata from a delivered render-grid frame. A full
    /// screen-anchored primary frame carrying scrollback (or explicitly
    /// reporting no history) completes hydration; deltas and frames that do
    /// not describe primary scrollback never do.
    /// A retained mirror accepts a live full frame only when its producer
    /// identity and history metadata still match the visible mirror. If those
    /// values changed, the visible screen may still be useful, but its
    /// scrollback must be rehydrated before a zero-row repaint is trusted.
    /// Once a retained replay has completed, normal history growth and
    /// row-space changes are accepted; a producer identity change still
    /// invalidates the local scrollback baseline.
    /// - Parameter frame: The accepted authoritative frame.
    public mutating func record(_ frame: MobileTerminalRenderGridFrame) {
        if retainedAcrossReconnect {
            guard frame.full else { return }
            guard matchesRetainedBaseline(frame) else {
                invalidate()
                return
            }
        }
        let hydrationSatisfied = retainedAcrossReconnect || (
            frame.anchor == .screen
                && frame.activeScreen == .primary
                && (frame.scrollbackRows > 0 || frame.historyRows == 0)
        )
        if frame.full,
           hasKnownProducerMetadata,
           !matchesRetainedProducer(frame),
           !hydrationSatisfied {
            // A producer change after a retained replay is still unsafe even
            // after the replay cleared `retainedAcrossReconnect`. A live full
            // frame without scrollback can paint the screen while leaving the
            // local primary history owned by the retired producer. Invalidate
            // that baseline so the next authoritative replay hydrates it.
            invalidate()
            return
        }
        renderEpoch = frame.renderEpoch.isEmpty ? nil : frame.renderEpoch
        historyRows = frame.historyRows
        rowSpaceRevision = frame.rowSpaceRevision
        if frame.full, hydrationSatisfied {
            hydrationNeeded = false
            retainedAcrossReconnect = false
        }
    }

    /// Determines whether a retained mirror must be rehydrated for a response.
    /// A changed producer epoch, history count, or row-space revision means the
    /// local scrollback can no longer be trusted and must be rehydrated.
    /// - Parameter frame: The candidate replay frame returned by the producer.
    /// - Returns: `true` when producer identity or history freshness is unknown
    ///   or changed; otherwise `false` for a safe zero-row repaint.
    public func requiresHydration(for frame: MobileTerminalRenderGridFrame) -> Bool {
        guard retainedAcrossReconnect else { return hydrationNeeded }
        return !matchesRetainedBaseline(frame)
    }

    private func matchesRetainedBaseline(
        _ frame: MobileTerminalRenderGridFrame
    ) -> Bool {
        guard let renderEpoch,
              let historyRows,
              let rowSpaceRevision,
              !frame.renderEpoch.isEmpty,
              let frameHistoryRows = frame.historyRows,
              let frameRowSpaceRevision = frame.rowSpaceRevision else {
            return false
        }
        return renderEpoch == frame.renderEpoch
            && historyRows == frameHistoryRows
            && rowSpaceRevision == frameRowSpaceRevision
    }

    private func matchesRetainedProducer(
        _ frame: MobileTerminalRenderGridFrame
    ) -> Bool {
        guard let renderEpoch,
              !frame.renderEpoch.isEmpty else {
            return false
        }
        return renderEpoch == frame.renderEpoch
    }

    private var hasKnownProducerMetadata: Bool {
        renderEpoch != nil || historyRows != nil || rowSpaceRevision != nil
    }
}
