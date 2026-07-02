import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

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

    private var payload: Payload
    var replacementScope: ReplacementScope?
    var viewportPolicy: MobileTerminalOutputViewportPolicy?

    var replaceable: Bool {
        replacementScope != nil
    }

    init(
        bytes: Data,
        replaceable: Bool,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil
    ) {
        self.payload = .bytes(bytes)
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

    /// True when the payload replays a full render-grid snapshot, whose bytes
    /// begin with an `ESC c` terminal reset. The apply side preserves the local
    /// viewport scroll position across these.
    var isFullReplacement: Bool {
        switch payload {
        case .bytes:
            false
        case .renderGrid(let frame):
            frame.full
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
