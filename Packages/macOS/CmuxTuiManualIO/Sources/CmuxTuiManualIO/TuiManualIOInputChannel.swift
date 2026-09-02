public import Foundation
import CmuxFoundation

/// Bridges encoded Ghostty input to one relay stdin handle.
///
/// Ghostty may call the manual-input handler from its IO thread. The channel
/// therefore keeps all mutable state behind a lock and serializes writes on a
/// private queue. Input is dropped while no relay is attached, because replaying
/// stale keystrokes into a newly reconnected terminal is unsafe.
public final class TuiManualIOInputChannel: @unchecked Sendable {
    private let lock = NSLock()
    private let policy: TuiManualIOPumpPolicy
    private var handle: FileHandle?
    private var lastGeometryClaim: TimeInterval = 0
    private var needsGeometryClaim = false
    private let queue = DispatchQueue(label: "cmux.tuiManualIO.stdin", qos: .userInitiated)
    private let maxQueuedBytes = 1 * 1024 * 1024
    private var queuedBytes = 0

    /// Creates a channel with the supplied wire policy.
    public init(policy: TuiManualIOPumpPolicy = TuiManualIOPumpPolicy()) {
        self.policy = policy
    }

    /// Swaps the live relay stdin. A fresh handle starts with geometry
    /// ownership because the relay claims its size during attach.
    public func setHandle(
        _ newHandle: FileHandle?,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        let oldHandle = handle
        handle = newHandle
        if newHandle != nil {
            lastGeometryClaim = now
            needsGeometryClaim = false
        }
        lock.unlock()
        // Keep replacement ordered after writes already queued for the old
        // relay, then close it. Without this, every reconnect can leak one
        // pipe descriptor and the old child may never observe stdin EOF.
        if let oldHandle, oldHandle !== newHandle {
            queue.async {
                try? oldHandle.close()
            }
        }
    }

    /// Forces the next user input to reclaim daemon-side geometry ownership.
    public func markGeometryOwnershipChanged() {
        lock.lock()
        needsGeometryClaim = true
        lock.unlock()
    }

    /// Sends a non-user control line when a relay is attached.
    public func send(_ line: Data) {
        lock.lock()
        let target = handle
        lock.unlock()
        guard let target else { return }
        enqueue(bytes: line.count) { [weak self] in
            defer { self?.releaseQueued(bytes: line.count) }
            do {
                try target.writeProcessPipeInput(line)
            } catch {
                self?.detachIfCurrent(target)
            }
        }
    }

    /// Sends user input, preceded by a geometry claim when required by focus
    /// ownership or by the claim interval. The serial queue preserves order.
    public func sendUserInput(
        _ line: Data,
        claimInterval: TimeInterval? = nil,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        let target = handle
        var claim = false
        let interval = claimInterval ?? policy.claimInterval
        if target != nil, needsGeometryClaim || now - lastGeometryClaim >= interval {
            lastGeometryClaim = now
            needsGeometryClaim = false
            claim = true
        }
        lock.unlock()
        guard let target else { return }
        let sendClaim = claim
        let claimLine = policy.claimGeometryLine
        let queuedBytes = line.count + (sendClaim ? claimLine.count : 0)
        enqueue(bytes: queuedBytes) { [weak self] in
            defer { self?.releaseQueued(bytes: queuedBytes) }
            do {
                if sendClaim {
                    try target.writeProcessPipeInput(claimLine)
                }
                try target.writeProcessPipeInput(line)
            } catch {
                self?.detachIfCurrent(target)
            }
        }
    }

    /// Closes and detaches the current handle. Relay stdin EOF is a clean
    /// detach and does not end the daemon terminal.
    public func closeHandle() {
        lock.lock()
        let target = handle
        handle = nil
        lock.unlock()
        guard let target else { return }
        queue.async {
            try? target.close()
        }
    }

    deinit {
        closeHandle()
    }

    @discardableResult
    private func enqueue(bytes: Int, operation: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard bytes <= maxQueuedBytes - queuedBytes else {
            lock.unlock()
            return false
        }
        queuedBytes += bytes
        lock.unlock()
        queue.async(execute: operation)
        return true
    }

    private func releaseQueued(bytes: Int) {
        lock.lock()
        queuedBytes = max(0, queuedBytes - bytes)
        lock.unlock()
    }

    private func detachIfCurrent(_ target: FileHandle) {
        lock.lock()
        guard handle === target else {
            lock.unlock()
            return
        }
        handle = nil
        lock.unlock()
        try? target.close()
    }
}
