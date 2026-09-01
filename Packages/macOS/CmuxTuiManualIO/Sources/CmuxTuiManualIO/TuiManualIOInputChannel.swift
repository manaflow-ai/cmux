public import Foundation

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
        queue.async {
            try? target.write(contentsOf: line)
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
        queue.async {
            if sendClaim {
                try? target.write(contentsOf: claimLine)
            }
            try? target.write(contentsOf: line)
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
}
