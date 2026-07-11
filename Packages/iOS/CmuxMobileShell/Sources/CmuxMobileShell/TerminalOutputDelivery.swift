import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

struct TerminalScrollReconciliation: Equatable, Sendable {
    let interactionEpoch: UInt64
    let clientRevision: UInt64
}

/// One terminal-output chunk waiting to be applied by a mounted mobile surface.
struct TerminalOutputDelivery: Equatable, Sendable {
    enum ReplacementScope: Equatable, Sendable {
        case byteViewport
        case renderGridViewport
        case viewportPolicy
    }

    private enum Payload: Equatable, Sendable {
        case bytes(Data)
        case renderGrid(MobileTerminalRenderGridFrame)
    }

    let deliveryID: UUID
    private var payload: Payload
    var replacementScope: ReplacementScope?
    var viewportPolicy: MobileTerminalOutputViewportPolicy?
    var scrollReconciliation: TerminalScrollReconciliation?
    /// An explicit authoritative viewport position. `nil` preserves the local
    /// position; `.some(0)` snaps to the bottom after a full history rebuild.
    var scrollbackOffsetFromBottomRows: Int?

    var replaceable: Bool {
        replacementScope != nil
    }

    init(
        deliveryID: UUID = UUID(),
        bytes: Data,
        replaceable: Bool,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        scrollbackOffsetFromBottomRows: Int? = nil
    ) {
        self.deliveryID = deliveryID
        self.payload = .bytes(bytes)
        self.replacementScope = replaceable ? (replacementScope ?? .byteViewport) : nil
        self.viewportPolicy = viewportPolicy
        self.scrollReconciliation = nil
        self.scrollbackOffsetFromBottomRows = scrollbackOffsetFromBottomRows.map { max(0, $0) }
    }

    init(
        deliveryID: UUID = UUID(),
        renderGrid frame: MobileTerminalRenderGridFrame,
        replaceable: Bool,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        scrollReconciliation: TerminalScrollReconciliation? = nil
    ) {
        self.deliveryID = deliveryID
        self.payload = .renderGrid(frame)
        self.replacementScope = replaceable ? (replacementScope ?? .renderGridViewport) : nil
        self.viewportPolicy = viewportPolicy
        self.scrollReconciliation = scrollReconciliation
        self.scrollbackOffsetFromBottomRows = frame.full && frame.activeScreen == .primary
            ? frame.scrollForwardRows
            : nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.payload == rhs.payload
            && lhs.replacementScope == rhs.replacementScope
            && lhs.viewportPolicy == rhs.viewportPolicy
            && lhs.scrollReconciliation == rhs.scrollReconciliation
            && lhs.scrollbackOffsetFromBottomRows == rhs.scrollbackOffsetFromBottomRows
    }

    var isRenderGrid: Bool {
        if case .renderGrid = payload { return true }
        return false
    }

    var isViewportRepaint: Bool {
        isRenderGrid || replacementScope == .byteViewport
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
    private var inFlight: TerminalOutputDelivery?
    private var inFlightClaimed = false
    private var pending: [TerminalOutputDelivery] = []
    private var pendingHeadIndex = 0

    var isIdle: Bool {
        inFlight == nil && pendingCount == 0
    }

    var pendingCount: Int {
        pending.count - pendingHeadIndex
    }

    var currentInFlight: TerminalOutputDelivery? {
        inFlight
    }

    mutating func enqueue(_ delivery: TerminalOutputDelivery) -> TerminalOutputDelivery? {
        guard inFlight != nil else {
            inFlight = delivery
            inFlightClaimed = false
            return delivery
        }
        appendPending(delivery)
        return nil
    }

    mutating func completeInFlight() -> TerminalOutputDelivery? {
        guard inFlight != nil else {
            pending.removeAll(keepingCapacity: false)
            pendingHeadIndex = 0
            return nil
        }
        guard let next = popPending() else {
            inFlight = nil
            inFlightClaimed = false
            pending.removeAll(keepingCapacity: true)
            pendingHeadIndex = 0
            return nil
        }
        inFlight = next
        inFlightClaimed = false
        return next
    }

    mutating func claimInFlight(deliveryID: UUID) -> Bool {
        guard inFlight?.deliveryID == deliveryID, !inFlightClaimed else { return false }
        inFlightClaimed = true
        return true
    }

    /// Drops viewport frames that have not entered Ghostty yet. A claimed
    /// delivery is already queued on the surface FIFO and therefore runs before
    /// a subsequently submitted local scroll. Raw PTY bytes and policy barriers
    /// remain ordered. Returns the newly promoted delivery, if the yielded
    /// current frame itself was discarded.
    mutating func discardUnclaimedViewportDeliveries() -> TerminalOutputDelivery? {
        discardPendingViewportDeliveries()
        guard inFlight?.isViewportRepaint == true, !inFlightClaimed else { return nil }
        inFlight = popPending()
        inFlightClaimed = false
        return inFlight
    }

    mutating func reset() {
        inFlight = nil
        inFlightClaimed = false
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

    private mutating func popPending() -> TerminalOutputDelivery? {
        guard pendingHeadIndex < pending.count else { return nil }
        let next = pending[pendingHeadIndex]
        pendingHeadIndex += 1
        compactPendingStorageIfNeeded()
        return next
    }

    private mutating func discardPendingViewportDeliveries() {
        guard pendingHeadIndex < pending.count else { return }
        pending = pending[pendingHeadIndex...].filter { !$0.isViewportRepaint }
        pendingHeadIndex = 0
    }
}
