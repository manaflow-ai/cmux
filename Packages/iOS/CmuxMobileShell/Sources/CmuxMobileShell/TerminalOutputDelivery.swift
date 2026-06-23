import CMUXMobileCore
import Foundation

/// One terminal-output chunk waiting to be applied by a mounted mobile surface.
struct TerminalOutputDelivery: Equatable, Sendable {
    private enum Payload: Equatable, Sendable {
        case bytes(Data)
        case renderGrid(MobileTerminalRenderGridFrame)
    }

    private var payload: Payload
    var replaceable: Bool
    var endSeq: UInt64?

    init(bytes: Data, replaceable: Bool, endSeq: UInt64? = nil) {
        self.payload = .bytes(bytes)
        self.replaceable = replaceable
        self.endSeq = endSeq
    }

    init(renderGrid frame: MobileTerminalRenderGridFrame, replaceable: Bool) {
        self.payload = .renderGrid(frame)
        self.replaceable = replaceable
        self.endSeq = frame.stateSeq
    }

    var bytes: Data {
        switch payload {
        case .bytes(let bytes):
            bytes
        case .renderGrid(let frame):
            frame.vtPatchBytes()
        }
    }
}

/// Backpressure queue for one mounted mobile terminal output stream.
///
/// Raw byte chunks are nonreplaceable barriers. Render-grid chunks that repaint
/// the whole viewport are replaceable while the iOS surface is still applying a
/// prior chunk, so fast scroll gestures can skip obsolete intermediate frames.
struct TerminalOutputDeliveryQueue: Sendable {
    private var inFlight = false
    private var currentInFlightEndSeq: UInt64?
    private var pending: [TerminalOutputDelivery] = []
    private var pendingHeadIndex = 0

    var inFlightEndSeq: UInt64? {
        inFlight ? currentInFlightEndSeq : nil
    }

    var isIdle: Bool {
        !inFlight && pendingCount == 0
    }

    var pendingCount: Int {
        pending.count - pendingHeadIndex
    }

    mutating func enqueue(_ delivery: TerminalOutputDelivery) -> TerminalOutputDelivery? {
        guard inFlight else {
            inFlight = true
            currentInFlightEndSeq = delivery.endSeq
            return delivery
        }
        appendPending(delivery)
        return nil
    }

    mutating func completeInFlight() -> TerminalOutputDelivery? {
        guard inFlight else {
            currentInFlightEndSeq = nil
            pending.removeAll(keepingCapacity: false)
            pendingHeadIndex = 0
            return nil
        }
        guard pendingHeadIndex < pending.count else {
            inFlight = false
            currentInFlightEndSeq = nil
            pending.removeAll(keepingCapacity: true)
            pendingHeadIndex = 0
            return nil
        }
        let next = pending[pendingHeadIndex]
        currentInFlightEndSeq = next.endSeq
        pendingHeadIndex += 1
        compactPendingStorageIfNeeded()
        return next
    }

    mutating func reset() {
        inFlight = false
        currentInFlightEndSeq = nil
        pending.removeAll(keepingCapacity: false)
        pendingHeadIndex = 0
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
    }

    private mutating func compactPendingStorageIfNeeded() {
        guard pendingHeadIndex > 32, pendingHeadIndex * 2 >= pending.count else { return }
        pending.removeFirst(pendingHeadIndex)
        pendingHeadIndex = 0
    }
}
