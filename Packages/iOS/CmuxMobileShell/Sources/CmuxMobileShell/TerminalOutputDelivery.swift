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
    /// Whether this is the surface's first full snapshot (a true cold attach).
    /// A cold attach uses the `ESC c` reset + scrollback-seeding replay; every
    /// later full frame (resize, resync, divergence repair) repaints the
    /// viewport in place so it never resets the scroll position of a user who is
    /// reading scrollback. Irrelevant for delta and raw-byte deliveries.
    var coldAttach: Bool

    init(bytes: Data, replaceable: Bool) {
        self.payload = .bytes(bytes)
        self.replaceable = replaceable
        self.coldAttach = true
    }

    init(renderGrid frame: MobileTerminalRenderGridFrame, replaceable: Bool, coldAttach: Bool = true) {
        self.payload = .renderGrid(frame)
        self.replaceable = replaceable
        self.coldAttach = coldAttach
    }

    var bytes: Data {
        switch payload {
        case .bytes(let bytes):
            bytes
        case .renderGrid(let frame):
            (frame.full && !coldAttach)
                ? MobileTerminalRenderGridReplay(frame).viewportRepaintBytes()
                : frame.vtPatchBytes()
        }
    }

    /// The authoritative grid hash the producer stamped on this render-grid
    /// frame, if any. `nil` for raw-byte deliveries and for frames from a
    /// producer that predates the hash. The consumer uses it to verify its
    /// applied grid and request a keyframe on divergence.
    var expectedGridHash: UInt64? {
        switch payload {
        case .bytes:
            nil
        case .renderGrid(let frame):
            frame.gridHash
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
