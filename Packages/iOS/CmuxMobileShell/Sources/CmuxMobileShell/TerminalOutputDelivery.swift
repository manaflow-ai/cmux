import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

/// One terminal-output chunk waiting to be applied by a mounted mobile surface.
struct TerminalOutputDelivery: Equatable, Sendable {
    struct ByteSequenceInterval: Equatable, Sendable {
        let start: UInt64
        let end: UInt64

        init?(start: UInt64, byteCount: Int) {
            guard byteCount >= 0 else { return nil }
            let (end, overflow) = start.addingReportingOverflow(UInt64(byteCount))
            guard !overflow else { return nil }
            self.start = start
            self.end = end
        }

        private init(start: UInt64, end: UInt64) {
            self.start = start
            self.end = end
        }

        func droppingPrefix(_ byteCount: Int) -> Self? {
            guard byteCount >= 0 else { return nil }
            let (trimmedStart, overflow) = start.addingReportingOverflow(UInt64(byteCount))
            guard !overflow, trimmedStart <= end else { return nil }
            return Self(start: trimmedStart, end: end)
        }
    }

    enum ReplacementScope: Equatable, Sendable {
        case byteViewport
        case renderGridViewport
        case viewportPolicy
    }

    private enum Payload: Equatable, Sendable {
        case bytes(Data)
        case renderGrid(MobileTerminalRenderGridFrame)
    }

    private let payload: Payload
    let byteSequenceInterval: ByteSequenceInterval?
    let replacementScope: ReplacementScope?
    let viewportPolicy: MobileTerminalOutputViewportPolicy?

    var replaceable: Bool {
        replacementScope != nil
    }

    init(
        bytes: Data,
        replaceable: Bool,
        byteSequenceInterval: ByteSequenceInterval? = nil,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil
    ) {
        self.payload = .bytes(bytes)
        self.byteSequenceInterval = byteSequenceInterval
        self.replacementScope = replaceable ? (replacementScope ?? .byteViewport) : nil
        self.viewportPolicy = viewportPolicy
    }

    init(
        renderGrid frame: MobileTerminalRenderGridFrame,
        replaceable: Bool,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil
    ) {
        self.payload = .renderGrid(frame)
        self.byteSequenceInterval = nil
        self.replacementScope = replaceable ? (replacementScope ?? .renderGridViewport) : nil
        self.viewportPolicy = viewportPolicy
    }

    var bytes: Data {
        switch payload {
        case .bytes(let bytes):
            bytes
        case .renderGrid(let frame):
            frame.vtPatchBytes()
        }
    }

    var renderGridFrame: MobileTerminalRenderGridFrame? {
        guard case .renderGrid(let frame) = payload else { return nil }
        return frame
    }

    func droppingBytePrefix(_ byteCount: Int) -> Self? {
        guard case .bytes(let bytes) = payload,
              byteCount >= 0,
              byteCount <= bytes.count,
              let byteSequenceInterval,
              let trimmedInterval = byteSequenceInterval.droppingPrefix(byteCount) else {
            return nil
        }
        return Self(
            bytes: Data(bytes.dropFirst(byteCount)),
            replaceable: replaceable,
            byteSequenceInterval: trimmedInterval,
            replacementScope: replacementScope,
            viewportPolicy: viewportPolicy
        )
    }
}

/// Bounded output retained while a replay barrier owns the surface.
///
/// Raw bytes remain ordered. Consecutive replaceable viewport deliveries
/// coalesce exactly like the live output queue, so a busy render-grid stream
/// cannot retain obsolete intermediate repaints before the barrier fails open.
struct TerminalReplayBarrierRetainedOutput: Sendable {
    private(set) var deliveries: [TerminalOutputDelivery] = []
    private var followUpReplayCoveredDeliveryCount: Int?

    mutating func append(_ delivery: TerminalOutputDelivery) {
        if let replacementScope = delivery.replacementScope,
           let lastIndex = deliveries.indices.last,
           lastIndex >= (followUpReplayCoveredDeliveryCount ?? 0),
           deliveries[lastIndex].replacementScope == replacementScope {
            deliveries[lastIndex] = delivery
        } else {
            deliveries.append(delivery)
        }
    }

    /// Freezes the retained prefix that the sole follow-up replay is about to
    /// capture. Later deliveries must not coalesce backward across this edge.
    mutating func markCoveredByFollowUpReplay() {
        followUpReplayCoveredDeliveryCount = deliveries.count
    }

    /// A successfully applied follow-up makes its frozen prefix obsolete.
    /// Failure leaves the prefix intact so fail-open can reconcile the entire
    /// bounded episode in original order.
    mutating func discardDeliveriesCoveredByFollowUpReplay() {
        guard let followUpReplayCoveredDeliveryCount else { return }
        deliveries.removeFirst(min(followUpReplayCoveredDeliveryCount, deliveries.count))
        self.followUpReplayCoveredDeliveryCount = nil
    }
}

/// Backpressure queue for one mounted mobile terminal output stream.
///
/// Raw byte chunks are nonreplaceable barriers. Render-grid chunks that repaint
/// the whole viewport are replaceable while the iOS surface is still applying a
/// prior chunk, so fast scroll gestures can skip obsolete intermediate frames.
struct TerminalOutputDeliveryQueue: Sendable {
    private var inFlight = false
    private var pending: [TerminalOutputDelivery] = []
    private var pendingHeadIndex = 0

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
    }

    private mutating func appendPending(_ delivery: TerminalOutputDelivery) {
        if let replacementScope = delivery.replacementScope,
           let lastIndex = pending.indices.last,
           lastIndex >= pendingHeadIndex,
           pending[lastIndex].replacementScope == replacementScope {
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
