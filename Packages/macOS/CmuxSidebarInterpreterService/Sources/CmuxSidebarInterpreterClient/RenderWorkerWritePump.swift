import Foundation
import Dispatch

/// One encoded host-to-worker message plus its bounded relaunch budget.
///
/// The pump owns blocking `write(2)` calls. Keeping this value Sendable lets
/// the supervising actor enqueue work and immediately return to deadlines,
/// worker-exit callbacks, and UI callers.
struct RenderWorkerOutboundWrite: Sendable {
    let data: Data
    let remainingRelaunches: Int
    let ackSequence: UInt64?

    func consumingRelaunch() -> RenderWorkerOutboundWrite? {
        guard remainingRelaunches > 0 else { return nil }
        return RenderWorkerOutboundWrite(
            data: data,
            remainingRelaunches: remainingRelaunches - 1,
            ackSequence: ackSequence
        )
    }
}

/// Serial blocking-I/O bridge for one render-worker generation.
///
/// `LengthPrefixedMessageChannel` intentionally uses blocking POSIX writes.
/// Those writes must never execute on `RenderWorkerClient`'s actor executor:
/// a full child pipe would otherwise prevent that same actor's ACK deadline
/// from terminating the child and making the pipe writable again.
final class RenderWorkerWritePump: @unchecked Sendable {
    private let channel: LengthPrefixedMessageChannel
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var cancelled = false

    init(channel: LengthPrefixedMessageChannel, generation: Int) {
        self.channel = channel
        queue = DispatchQueue(
            label: "com.cmuxterm.sidebar-render-writer.\(generation)",
            qos: .userInitiated
        )
    }

    func enqueue(
        _ outbound: RenderWorkerOutboundWrite,
        onFailure: @escaping @Sendable () -> Void
    ) {
        queue.async { [self] in
            guard !isCancelled else { return }
            do {
                try channel.sendMessage(outbound.data)
            } catch {
                guard !isCancelled else { return }
                onFailure()
            }
        }
    }

    func cancel() {
        stateLock.withLock {
            cancelled = true
        }
    }

    private var isCancelled: Bool {
        stateLock.withLock { cancelled }
    }
}
