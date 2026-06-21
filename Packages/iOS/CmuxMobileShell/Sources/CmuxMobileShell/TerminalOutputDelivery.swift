import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

/// One terminal-output chunk waiting to be applied by a mounted mobile surface.
struct TerminalOutputDelivery: Equatable, Sendable {
    private enum Payload: Equatable, Sendable {
        case bytes(Data)
        case renderGrid(MobileTerminalRenderGridEnvelope)
    }

    private var payload: Payload
    var replaceable: Bool

    init(bytes: Data, replaceable: Bool) {
        self.payload = .bytes(bytes)
        self.replaceable = replaceable
    }

    init(renderGrid envelope: MobileTerminalRenderGridEnvelope, replaceable: Bool) {
        self.payload = .renderGrid(envelope)
        self.replaceable = replaceable
    }

    var renderGridStateSeq: UInt64? {
        switch payload {
        case .bytes:
            nil
        case .renderGrid(let envelope):
            envelope.frame.stateSeq
        }
    }

    func chunk(streamToken: UUID) -> MobileTerminalOutputChunk {
        switch payload {
        case .bytes(let data):
            MobileTerminalOutputChunk(data: data, streamToken: streamToken)
        case .renderGrid(let envelope):
            MobileTerminalOutputChunk(renderGrid: envelope, streamToken: streamToken)
        }
    }
}

/// Backpressure queue for one mounted mobile terminal output stream.
///
/// Raw byte chunks are nonreplaceable barriers by default, though callers may
/// mark display-only raw frames as replaceable. Render-grid chunks stay
/// nonreplaceable because the iOS semantic mirror uses every delta to build
/// scrollback history. If ordered render-grid delivery falls too far behind, the
/// queue drops its pending backlog and asks the owner to repair with a fresh
/// render-grid snapshot instead of growing without bound.
struct TerminalOutputDeliveryQueue: Sendable {
    private static let maxPendingRenderGridDeliveries = 128

    private var inFlight = false
    private var pending: [TerminalOutputDelivery] = []
    private var pendingHeadIndex = 0
    private var renderGridOverflowStateSeq: UInt64?

    var isIdle: Bool {
        !inFlight && pendingCount == 0
    }

    var pendingCount: Int {
        pending.count - pendingHeadIndex
    }

    mutating func enqueue(_ delivery: TerminalOutputDelivery) -> TerminalOutputDelivery? {
        guard inFlight else {
            inFlight = true
            return delivery
        }
        appendPending(delivery)
        return nil
    }

    mutating func completeInFlight() -> TerminalOutputDelivery? {
        guard inFlight else {
            pending.removeAll(keepingCapacity: false)
            pendingHeadIndex = 0
            return nil
        }
        guard pendingHeadIndex < pending.count else {
            inFlight = false
            pending.removeAll(keepingCapacity: true)
            pendingHeadIndex = 0
            return nil
        }
        let next = pending[pendingHeadIndex]
        pendingHeadIndex += 1
        compactPendingStorageIfNeeded()
        return next
    }

    mutating func reset() {
        inFlight = false
        pending.removeAll(keepingCapacity: false)
        pendingHeadIndex = 0
        renderGridOverflowStateSeq = nil
    }

    mutating func consumeRenderGridOverflowStateSeq() -> UInt64? {
        defer { renderGridOverflowStateSeq = nil }
        return renderGridOverflowStateSeq
    }

    private mutating func appendPending(_ delivery: TerminalOutputDelivery) {
        if delivery.replaceable,
           let lastIndex = pending.indices.last,
           lastIndex >= pendingHeadIndex,
           pending[lastIndex].replaceable {
            pending[lastIndex] = delivery
        } else {
            pending.append(delivery)
        }
        guard delivery.renderGridStateSeq != nil,
              pendingCount > Self.maxPendingRenderGridDeliveries else {
            return
        }
        renderGridOverflowStateSeq = delivery.renderGridStateSeq
        pending.removeAll(keepingCapacity: true)
        pendingHeadIndex = 0
    }

    private mutating func compactPendingStorageIfNeeded() {
        guard pendingHeadIndex > 32, pendingHeadIndex * 2 >= pending.count else { return }
        pending.removeFirst(pendingHeadIndex)
        pendingHeadIndex = 0
    }
}
