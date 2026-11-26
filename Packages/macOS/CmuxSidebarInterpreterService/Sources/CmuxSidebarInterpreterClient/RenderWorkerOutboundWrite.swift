import Foundation

/// One encoded host-to-worker message plus its bounded relaunch budget.
///
/// The semantic message is retained when available so the write pump can
/// coalesce replaceable state without decoding JSON on its I/O path.
struct RenderWorkerOutboundWrite: Sendable {
    enum CoalescingKey: Equatable, Sendable {
        case scene
        case geometry
        case drag
        case scroll
    }

    let data: Data
    let remainingRelaunches: Int
    let ackSequence: UInt64?
    private let message: RenderWorkerInbound?

    init(
        data: Data,
        remainingRelaunches: Int,
        ackSequence: UInt64?
    ) {
        self.init(
            data: data,
            message: nil,
            remainingRelaunches: remainingRelaunches,
            ackSequence: ackSequence
        )
    }

    init?(
        message: RenderWorkerInbound,
        remainingRelaunches: Int,
        ackSequence: UInt64?
    ) {
        guard let data = try? JSONEncoder().encode(message) else { return nil }
        self.init(
            data: data,
            message: message,
            remainingRelaunches: remainingRelaunches,
            ackSequence: ackSequence
        )
    }

    var coalescingKey: CoalescingKey? {
        guard let message else { return nil }
        switch message {
        case .scene:
            return .scene
        case .resize:
            return .geometry
        case let .pointer(event):
            switch event.kind {
            case .drag:
                return .drag
            case .scroll:
                return .scroll
            case .down, .up:
                return nil
            }
        case .reloadSidebars:
            return nil
        }
    }

    func consumingRelaunch() -> RenderWorkerOutboundWrite? {
        guard remainingRelaunches > 0 else { return nil }
        return RenderWorkerOutboundWrite(
            data: data,
            message: message,
            remainingRelaunches: remainingRelaunches - 1,
            ackSequence: ackSequence
        )
    }

    /// Combines this queued write with a newer write carrying the same key.
    ///
    /// Scene, geometry, and drag updates are snapshots, so only the newest is
    /// useful. Adjacent scroll deltas are additive and preserve the latest
    /// pointer location.
    func coalescing(with newer: RenderWorkerOutboundWrite) -> RenderWorkerOutboundWrite? {
        guard let key = coalescingKey, key == newer.coalescingKey else { return nil }
        switch key {
        case .scene, .geometry, .drag:
            return newer
        case .scroll:
            guard let message,
                  case let .pointer(previousEvent) = message,
                  let newerMessage = newer.message,
                  case var .pointer(combinedEvent) = newerMessage else {
                return nil
            }
            combinedEvent.deltaX += previousEvent.deltaX
            combinedEvent.deltaY += previousEvent.deltaY
            return RenderWorkerOutboundWrite(
                message: .pointer(combinedEvent),
                remainingRelaunches: newer.remainingRelaunches,
                ackSequence: newer.ackSequence
            )
        }
    }

    private init(
        data: Data,
        message: RenderWorkerInbound?,
        remainingRelaunches: Int,
        ackSequence: UInt64?
    ) {
        self.data = data
        self.message = message
        self.remainingRelaunches = remainingRelaunches
        self.ackSequence = ackSequence
    }
}
